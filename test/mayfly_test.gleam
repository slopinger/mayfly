import gleam/dict
import gleam/erlang/process
import gleeunit
import gleeunit/should
import mayfly
import mayfly/store
import simplifile
import wisp

pub fn main() {
  gleeunit.main()
}

pub fn lifetime_test() {
  mayfly.lifetime("1h") |> should.equal(Ok(1))
  mayfly.lifetime("12h") |> should.equal(Ok(12))
  mayfly.lifetime("24h") |> should.equal(Ok(24))
  mayfly.lifetime("72h") |> should.equal(Ok(72))
  mayfly.lifetime("-1") |> should.equal(Error(Nil))
  mayfly.lifetime("2h") |> should.equal(Error(Nil))
}

pub fn validation_test() {
  store.valid_id("../../etc/passwd") |> should.be_false
  store.valid_id(store.token()) |> should.be_true
  mayfly.safe_name("C:\\fakepath\\hello\n.txt") |> should.equal("hello.txt")
  let file = wisp.UploadedFile("test.txt", "/tmp/not-real")
  mayfly.validate_form(wisp.FormData([], [#("file", file)]))
  |> should.equal(Ok(#(file, 1)))
  mayfly.validate_form(
    wisp.FormData([#("time", "1h"), #("time", "72h")], [#("file", file)]),
  )
  |> should.be_error
  mayfly.validate_form(wisp.FormData([], [#("file", file), #("file", file)]))
  |> should.be_error
  mayfly.validate_form(
    wisp.FormData([#("reqtype", "urlupload")], [#("file", file)]),
  )
  |> should.be_error
}

pub fn lifecycle_test() {
  let dir = "/tmp/mayfly-test-" <> store.token()
  let assert Ok(_) = simplifile.create_directory(dir)
  let state = store.start(dir)
  let path = dir <> "/temporary"
  let assert Ok(_) = simplifile.write(path, "test payload")
  let secret = store.token()
  let assert Ok(e) =
    process.call(state, 5000, store.Publish(path, "test.txt", 1, secret, _))
  process.call(state, 5000, store.Lookup(e.id, _)) |> should.equal(Ok(e))
  { e.expires >= store.now() + 3598 } |> should.be_true
  process.call(state, 5000, store.Delete(e.id, "wrong", _)) |> should.be_error
  let reloaded = store.load(dir)
  dict.get(reloaded.entries, e.id) |> should.equal(Ok(e))
  process.call(state, 5000, store.Delete(e.id, secret, _))
  |> should.equal(Ok(Nil))
  process.call(state, 5000, store.Lookup(e.id, _)) |> should.be_error
  simplifile.exists(dir <> "/" <> e.id, follow_links: False)
  |> should.equal(Ok(False))
  let _ = simplifile.delete(dir)
}

pub fn expiry_and_orphan_test() {
  let dir = "/tmp/mayfly-test-" <> store.token()
  let assert Ok(_) = simplifile.create_directory(dir)
  let id = store.token()
  let e = store.Entry(id, "old.txt", store.now() - 1, "hash", 3)
  let assert Ok(_) = simplifile.write(dir <> "/" <> id, "old")
  let assert Ok(_) =
    simplifile.write(dir <> "/" <> id <> ".json", store.encode(e))
  let orphan = store.token()
  let assert Ok(_) = simplifile.write(dir <> "/" <> orphan, "orphan")
  let assert Ok(_) = simplifile.write(dir <> "/crashed.tmp", "partial")
  let state = store.load(dir)
  dict.size(state.entries) |> should.equal(0)
  simplifile.read_directory(dir) |> should.equal(Ok([]))
  let _ = simplifile.delete(dir)
}

pub fn limits_test() {
  let dir = "/tmp/mayfly-test-" <> store.token()
  let state = store.start(dir)
  process.call(state, 5000, store.Begin("ip", _)) |> should.equal(Ok(Nil))
  process.call(state, 5000, store.Begin("ip", _)) |> should.equal(Ok(Nil))
  process.call(state, 5000, store.Begin("ip", _)) |> should.equal(Ok(Nil))
  process.call(state, 5000, store.Begin("ip", _)) |> should.equal(Ok(Nil))
  process.call(state, 5000, store.Begin("ip", _)) |> should.equal(Error(503))
  process.send(state, store.End)
  process.call(state, 5000, store.Begin("ip", _)) |> should.equal(Ok(Nil))
  let full =
    store.State(
      dir,
      dict.from_list([
        #(
          "x",
          store.Entry("x", "x", store.now() + 3600, "hash", store.max_storage),
        ),
      ]),
      dict.new(),
      0,
    )
  store.used(full) |> should.equal(store.max_storage)
  let _ = simplifile.delete(dir)
}
