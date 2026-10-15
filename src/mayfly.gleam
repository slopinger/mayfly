import envoy
import exception
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import mayfly/store
import mist
import simplifile
import wisp
import wisp/wisp_mist

pub fn main() {
  let dir = envoy.get("MAYFLY_DATA") |> result.unwrap("./data")
  let base = envoy.get("MAYFLY_URL") |> result.unwrap("http://127.0.0.1:8791")
  let port =
    envoy.get("MAYFLY_PORT") |> result.try(int.parse) |> result.unwrap(8791)
  // Wisp must stage files on the data filesystem so publication can rename
  // atomically (the host's /tmp may be tmpfs or another mount).
  let staging = dir <> "/tmp"
  let assert Ok(_) = simplifile.create_directory_all(dir)
  case simplifile.delete(staging) {
    Ok(_) | Error(simplifile.Enoent) -> Nil
    Error(_) -> panic as "Cannot clear interrupted upload staging"
  }
  let assert Ok(_) = simplifile.create_directory_all(staging)
  envoy.set("TMPDIR", staging)
  let state = store.start(dir)
  let _ = process.spawn(fn() { cleaner(state) })
  let secret = wisp.random_string(64)
  let assert Ok(_) =
    fn(req) { handle(req, state, dir, base) }
    |> wisp_mist.handler(secret)
    |> mist.new
    |> mist.bind("127.0.0.1")
    |> mist.port(port)
    |> mist.start
  process.sleep_forever()
}

fn cleaner(state: process.Subject(store.Message)) {
  process.sleep(60_000)
  process.send(state, store.Clean)
  cleaner(state)
}

pub fn handle(
  req: wisp.Request,
  state: process.Subject(store.Message),
  dir: String,
  base: String,
) -> wisp.Response {
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  route(req, state, dir, base)
  |> wisp.set_header("x-content-type-options", "nosniff")
  |> wisp.set_header("referrer-policy", "no-referrer")
  |> wisp.set_header("cache-control", "no-store")
  |> wisp.set_header(
    "content-security-policy",
    case string.starts_with(req.path, "/f/") {
      True -> "sandbox; default-src 'none'"
      False ->
        "default-src 'none'; img-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'; sandbox allow-scripts allow-same-origin allow-forms allow-downloads allow-modals"
    },
  )
}

fn route(
  req: wisp.Request,
  state: process.Subject(store.Message),
  dir: String,
  base: String,
) -> wisp.Response {
  case wisp.path_segments(req) {
    ["api", "upload"] | ["resources", "internals", "api.php"] ->
      upload(req, state, base)
    ["f", id] -> {
      use <- wisp.require_method(req, http.Get)
      case store.valid_id(id) {
        False -> wisp.not_found()
        True -> {
          case process.call(state, 5000, store.Lookup(id, _)) {
            Error(_) -> wisp.not_found()
            Ok(e) ->
              wisp.file_download(
                wisp.ok(),
                named: safe_name(e.name),
                from: dir <> "/" <> id,
              )
              |> wisp.set_header("content-type", "application/octet-stream")
              |> wisp.set_header(
                "content-security-policy",
                "sandbox; default-src 'none'",
              )
          }
        }
      }
    }
    ["delete", id, secret] -> {
      use <- wisp.require_method(req, http.Delete)
      case store.valid_id(id) && store.valid_id(secret) {
        False -> wisp.not_found()
        True ->
          case process.call(state, 5000, store.Delete(id, secret, _)) {
            Ok(_) -> wisp.no_content()
            Error(_) -> wisp.not_found()
          }
      }
    }
    ["healthz"] -> {
      use <- wisp.require_method(req, http.Get)
      wisp.ok() |> wisp.string_body("ok\n")
    }
    [] -> static(req, "index.html", "text/html; charset=utf-8")
    ["style.css"] -> static(req, "style.css", "text/css; charset=utf-8")
    ["app.js"] -> static(req, "app.js", "text/javascript; charset=utf-8")
    [asset]
      if asset == "mascot-disk.png"
      || asset == "mascot-tea.png"
      || asset == "mascot-wave.png"
    -> {
      use <- wisp.require_method(req, http.Get)
      let assert Ok(root) = wisp.priv_directory("mayfly")
      wisp.file_download(
        wisp.ok(),
        named: asset,
        from: root <> "/web/" <> asset,
      )
      |> wisp.set_header("content-type", "image/png")
      |> wisp.set_header("content-disposition", "inline")
    }
    _ -> wisp.not_found()
  }
}

fn static(
  req: wisp.Request,
  file: String,
  content_type: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Get)
  let assert Ok(root) = wisp.priv_directory("mayfly")
  case simplifile.read(root <> "/web/" <> file) {
    Ok(text) ->
      wisp.ok()
      |> wisp.string_body(text)
      |> wisp.set_header("content-type", content_type)
    Error(_) -> wisp.internal_server_error()
  }
}

pub fn safe_name(name: String) -> String {
  name
  |> string.replace("\\", "/")
  |> string.split("/")
  |> list.last
  |> result.unwrap("file")
  |> string.to_graphemes
  |> list.filter(fn(c) { c != "\r" && c != "\n" && c != "\u{0}" && c != "\"" })
  |> string.join("")
  |> string.slice(0, 180)
}

pub fn lifetime(value: String) -> Result(Int, Nil) {
  case value {
    "1h" | "1" -> Ok(1)
    "12h" | "12" -> Ok(12)
    "24h" | "24" -> Ok(24)
    "72h" | "72" -> Ok(72)
    _ -> Error(Nil)
  }
}

fn upload(
  req: wisp.Request,
  state: process.Subject(store.Message),
  base: String,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  case request.get_header(req, "origin") {
    Ok(origin) if origin != base ->
      wisp.response(403) |> wisp.string_body("Origin rejected")
    _ -> {
      // Caddy overwrites this header, and Mist listens only on loopback.
      let ip = request.get_header(req, "x-real-ip") |> result.unwrap("local")
      case process.call(state, 5000, store.Begin(ip, _)) {
        Error(code) ->
          wisp.response(code)
          |> wisp.string_body("Upload limit reached; try later")
          |> wisp.set_header("retry-after", "3600")
        Ok(_) -> {
          use <- exception.defer(fn() { process.send(state, store.End) })
          let req =
            req
            |> wisp.set_max_files_size(store.max_file)
            |> wisp.set_max_body_size(8192)
            |> wisp.set_read_chunk_size(65_536)
          use form <- wisp.require_form(req)
          case validate_form(form) {
            Error(reason) -> wisp.bad_request(reason)
            Ok(#(file, hours)) -> {
              let secret = store.token()
              case
                process.call(state, 10_000, store.Publish(
                  file.path,
                  safe_name(file.file_name),
                  hours,
                  secret,
                  _,
                ))
              {
                Error(_) ->
                  wisp.response(503)
                  |> wisp.string_body(
                    "Could not store file; choose a nonempty file up to 200 MiB",
                  )
                Ok(e) -> {
                  let url = base <> "/f/" <> e.id
                  case req.path {
                    "/resources/internals/api.php" ->
                      wisp.ok() |> wisp.string_body(url <> "\n")
                    _ ->
                      json.object([
                        #("url", json.string(url)),
                        #(
                          "delete_url",
                          json.string(
                            base <> "/delete/" <> e.id <> "/" <> secret,
                          ),
                        ),
                        #("expires", json.int(e.expires * 1000)),
                        #("name", json.string(e.name)),
                        #("size", json.int(e.size)),
                      ])
                      |> json.to_string
                      |> wisp.json_response(200)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

pub fn validate_form(
  form: wisp.FormData,
) -> Result(#(wisp.UploadedFile, Int), String) {
  case form.files {
    [#(key, file)] if key == "fileToUpload" || key == "file" -> {
      let keys = list.map(form.values, fn(pair) { pair.0 })
      case
        list.length(keys) != list.length(list.unique(keys))
        || !list.all(keys, fn(k) { k == "time" || k == "reqtype" })
      {
        True -> Error("Duplicate or unknown fields")
        False -> {
          let reqtype =
            list.key_find(form.values, "reqtype") |> result.unwrap("fileupload")
          case reqtype != "fileupload" {
            True -> Error("reqtype must be fileupload")
            False -> {
              list.key_find(form.values, "time")
              |> result.unwrap("1h")
              |> lifetime
              |> result.replace_error("Choose 1h, 12h, 24h or 72h")
              |> result.map(fn(hours) { #(file, hours) })
            }
          }
        }
      }
    }
    _ -> Error("Exactly one file is required")
  }
}
