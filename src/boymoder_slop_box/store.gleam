import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import simplifile

pub const max_file = 209_715_200

pub const max_storage = 10_737_418_240

pub type Entry {
  Entry(id: String, name: String, expires: Int, delete_hash: String, size: Int)
}

pub type State {
  State(
    dir: String,
    entries: Dict(String, Entry),
    rates: Dict(String, List(Int)),
    active: Int,
  )
}

pub type Message {
  Begin(ip: String, reply: Subject(Result(Nil, Int)))
  End
  Publish(
    path: String,
    name: String,
    hours: Int,
    secret: String,
    reply: Subject(Result(Entry, Nil)),
  )
  Lookup(id: String, reply: Subject(Result(Entry, Nil)))
  Delete(id: String, secret: String, reply: Subject(Result(Nil, Nil)))
  Clean
}

@external(erlang, "boymoder_slop_box_clock", "now")
pub fn now() -> Int

pub fn token() -> String {
  crypto.strong_random_bytes(16) |> bit_array.base16_encode |> string.lowercase
}

pub fn hash(secret: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(secret))
  |> bit_array.base16_encode
}

pub fn valid_id(id: String) -> Bool {
  string.length(id) == 32
  && string.to_graphemes(id)
  |> list.all(fn(c) { string.contains("0123456789abcdef", c) })
}

pub fn encode(e: Entry) -> String {
  json.object([
    #("id", json.string(e.id)),
    #("name", json.string(e.name)),
    #("expires", json.int(e.expires)),
    #("delete_hash", json.string(e.delete_hash)),
    #("size", json.int(e.size)),
  ])
  |> json.to_string
}

pub fn decode_entry(text: String) -> Result(Entry, Nil) {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use name <- decode.field("name", decode.string)
    use expires <- decode.field("expires", decode.int)
    use delete_hash <- decode.field("delete_hash", decode.string)
    use size <- decode.field("size", decode.int)
    decode.success(Entry(id, name, expires, delete_hash, size))
  }
  json.parse(text, decoder) |> result.replace_error(Nil)
}

fn remove(dir: String, e: Entry) -> Bool {
  let path = dir <> "/" <> e.id
  case simplifile.delete_file(path) {
    Ok(_) | Error(simplifile.Enoent) -> {
      let _ = simplifile.delete_file(path <> ".json")
      True
    }
    Error(_) -> False
  }
}

pub fn cleanup(state: State) -> State {
  let entries =
    dict.filter(state.entries, fn(_, e) {
      case e.expires <= now() {
        True -> !remove(state.dir, e)
        False -> True
      }
    })
  let rates =
    dict.map_values(state.rates, fn(_, times) {
      list.filter(times, fn(t) { t > now() - 3600 })
    })
    |> dict.filter(fn(_, times) { !list.is_empty(times) })
  State(..state, entries: entries, rates: rates)
}

pub fn load(dir: String) -> State {
  let assert Ok(_) = simplifile.create_directory_all(dir)
  let assert Ok(files) = simplifile.read_directory(dir)
  let entries =
    list.filter_map(files, fn(file) {
      case string.ends_with(file, ".json") {
        False -> Error(Nil)
        True -> {
          use text <- result.try(
            simplifile.read(dir <> "/" <> file) |> result.replace_error(Nil),
          )
          use e <- result.try(decode_entry(text))
          case valid_id(e.id) && file == e.id <> ".json" {
            True -> Ok(#(e.id, e))
            False -> Error(Nil)
          }
        }
      }
    })
    |> dict.from_list
  // Interrupted publications may leave unreferenced data or temporary metadata.
  list.each(files, fn(file) {
    case
      valid_id(file)
      && !dict.has_key(entries, file)
      || string.ends_with(file, ".tmp")
    {
      True -> {
        let _ = simplifile.delete_file(dir <> "/" <> file)
        Nil
      }
      False -> Nil
    }
  })
  cleanup(State(dir, entries, dict.new(), 0))
}

pub fn start(dir: String) -> Subject(Message) {
  let assert Ok(started) =
    actor.new(load(dir)) |> actor.on_message(handle) |> actor.start
  started.data
}

pub fn used(state: State) -> Int {
  dict.values(state.entries) |> list.fold(0, fn(total, e) { total + e.size })
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Begin(ip, reply) -> {
      let state = cleanup(state)
      let recent = dict.get(state.rates, ip) |> result.unwrap([])
      let recent_count = list.length(recent)
      let rate_count = dict.size(state.rates)
      let answer = case Nil {
        _ if state.active >= 4 -> Error(503)
        _ if recent_count >= 20 -> Error(429)
        _ if rate_count >= 10_000 -> Error(503)
        _ ->
          case used(state) + { state.active + 1 } * max_file > max_storage {
            True -> Error(507)
            False -> Ok(Nil)
          }
      }
      process.send(reply, answer)
      case answer {
        Ok(_) ->
          actor.continue(
            State(
              ..state,
              active: state.active + 1,
              rates: dict.insert(state.rates, ip, [now(), ..recent]),
            ),
          )
        Error(_) -> actor.continue(state)
      }
    }
    End -> actor.continue(State(..state, active: int.max(0, state.active - 1)))
    Publish(path, name, hours, secret, reply) -> {
      let saved = publish(state, path, name, hours, secret)
      process.send(reply, saved)
      case saved {
        Ok(e) ->
          actor.continue(
            State(..state, entries: dict.insert(state.entries, e.id, e)),
          )
        Error(_) -> actor.continue(state)
      }
    }
    Lookup(id, reply) -> {
      let answer = case dict.get(state.entries, id) {
        Ok(e) ->
          case e.expires > now() {
            True -> Ok(e)
            False -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
      process.send(reply, answer)
      actor.continue(state)
    }
    Delete(id, secret, reply) -> {
      let found = dict.get(state.entries, id)
      let answer = case found {
        Ok(e) ->
          case
            e.expires > now()
            && crypto.secure_compare(
              bit_array.from_string(e.delete_hash),
              bit_array.from_string(hash(secret)),
            )
          {
            True ->
              case remove(state.dir, e) {
                True -> Ok(Nil)
                False -> Error(Nil)
              }
            False -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
      process.send(reply, answer)
      case answer {
        Ok(_) ->
          actor.continue(
            State(..state, entries: dict.delete(state.entries, id)),
          )
        Error(_) -> actor.continue(state)
      }
    }
    Clean -> actor.continue(cleanup(state))
  }
}

fn publish(
  state: State,
  temp: String,
  name: String,
  hours: Int,
  secret: String,
) -> Result(Entry, Nil) {
  use info <- result.try(
    simplifile.file_info(temp) |> result.replace_error(Nil),
  )
  case
    info.size > 0
    && info.size <= max_file
    && used(state) + info.size <= max_storage
  {
    False -> Error(Nil)
    True -> {
      let e =
        Entry(token(), name, now() + hours * 3600, hash(secret), info.size)
      let path = state.dir <> "/" <> e.id
      use _ <- result.try(
        simplifile.rename(temp, path) |> result.replace_error(Nil),
      )
      let saved = {
        use _ <- result.try(simplifile.write(path <> ".tmp", encode(e)))
        simplifile.rename(path <> ".tmp", path <> ".json")
      }
      case saved {
        Ok(_) -> Ok(e)
        Error(_) -> {
          let _ = simplifile.delete_file(path)
          let _ = simplifile.delete_file(path <> ".tmp")
          Error(Nil)
        }
      }
    }
  }
}
