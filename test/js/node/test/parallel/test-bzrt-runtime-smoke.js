"use strict";

const assert = require("node:assert");

let server;

new Response("ok")
  .text()
  .then(body => {
    assert.strictEqual(body, "ok");
    server = Bun.serve({
      port: 0,
      fetch() {
        return new Response("ok", { headers: { "x-bzrt": "1" } });
      },
    });
    return server;
  })
  .then(async server => {
    const curl = Bun.spawn({ cmd: ["curl", "--silent", server.url] });
    assert.strictEqual(await new Response(curl.stdout).text(), "ok");
    return fetch(server.url).then(response => ({ response, server }));
  })
  .then(async ({ response, server }) => {
    assert.strictEqual(response.status, 200);
    assert.strictEqual(response.headers.get("x-bzrt"), "1");
    assert.strictEqual(await response.text(), "ok");
    server.stop(true);
  })
  .catch(error => {
    server?.stop(true);
    throw error;
  });
