/**
 * All new tests in this file should also run in Node.js.
 *
 * Do not add any tests that only run in Bun.
 *
 * A handful of older tests do not run in Node in this file. These tests should be updated to run in Node, or deleted.
 */
var __addDisposableResource = (this && this.__addDisposableResource) || function (env, value, async) {
    if (value !== null && value !== void 0) {
        if (typeof value !== "object" && typeof value !== "function") throw new TypeError("Object expected.");
        var dispose, inner;
        if (async) {
            if (!Symbol.asyncDispose) throw new TypeError("Symbol.asyncDispose is not defined.");
            dispose = value[Symbol.asyncDispose];
        }
        if (dispose === void 0) {
            if (!Symbol.dispose) throw new TypeError("Symbol.dispose is not defined.");
            dispose = value[Symbol.dispose];
            if (async) inner = dispose;
        }
        if (typeof dispose !== "function") throw new TypeError("Object not disposable.");
        if (inner) dispose = function() { try { inner.call(this); } catch (e) { return Promise.reject(e); } };
        env.stack.push({ value: value, dispose: dispose, async: async });
    }
    else if (async) {
        env.stack.push({ async: true });
    }
    return value;
};
var __disposeResources = (this && this.__disposeResources) || (function (SuppressedError) {
    return function (env) {
        function fail(e) {
            env.error = env.hasError ? new SuppressedError(e, env.error, "An error was suppressed during disposal.") : e;
            env.hasError = true;
        }
        var r, s = 0;
        function next() {
            while (r = env.stack.pop()) {
                try {
                    if (!r.async && s === 1) return s = 0, env.stack.push(r), Promise.resolve().then(next);
                    if (r.dispose) {
                        var result = r.dispose.call(r.value);
                        if (r.async) return s |= 2, Promise.resolve(result).then(next, function(e) { fail(e); return next(); });
                    }
                    else s |= 1;
                }
                catch (e) {
                    fail(e);
                }
            }
            if (s === 1) return env.hasError ? Promise.reject(env.error) : Promise.resolve();
            if (env.hasError) throw env.error;
        }
        return next();
    };
})(typeof SuppressedError === "function" ? SuppressedError : function (error, suppressed, message) {
    var e = new Error(message);
    return e.name = "SuppressedError", e.error = error, e.suppressed = suppressed, e;
});
import { describe, test } from "node:test";
import assert from "node:assert";
function expect(value) {
    return {
        toBe: (expected) => {
            assert.strictEqual(value, expected);
        },
        toContain: (expected) => {
            assert.ok(value.includes(expected));
        },
        toBeInstanceOf: (expected) => {
            assert.ok(value instanceof expected);
        },
        toBeGreaterThan: (expected) => {
            assert.ok(value > expected);
        },
        toBeLessThan: (expected) => {
            assert.ok(value < expected);
        },
        toEqual: (expected) => {
            assert.deepStrictEqual(value, expected);
        },
        not: {
            toBe: (expected) => {
                assert.notStrictEqual(value, expected);
            },
            toContain: (expected) => {
                assert.ok(!value.includes(expected));
            },
            toBeInstanceOf: (expected) => {
                assert.ok(!(value instanceof expected));
            },
            toBeGreaterThan: (expected) => {
                assert.ok(!(value > expected));
            },
            toBeLessThan: (expected) => {
                assert.ok(!(value < expected));
            },
            toEqual: (expected) => {
                assert.notDeepStrictEqual(value, expected);
            },
        },
    };
}
import http from "http";
import { createProxy } from "proxy";
import { once } from "node:events";
import net from "node:net";
function connectClient(proxyAddress, targetAddress, add_http_prefix) {
    const client = net.connect({ port: proxyAddress.port, host: proxyAddress.address }, () => {
        client.write(`CONNECT ${add_http_prefix ? "http://" : ""}${targetAddress.address}:${targetAddress.port} HTTP/1.1\r\nHost: ${targetAddress.address}:${targetAddress.port}\r\nProxy-Authorization: Basic dXNlcjpwYXNzd29yZA==\r\n\r\n`);
    });
    const received = [];
    const { promise, resolve, reject } = Promise.withResolvers();
    client.on("data", data => {
        if (data.toString().includes("200 Connection established")) {
            client.write("GET / HTTP/1.1\r\nHost: www.example.com:80\r\nConnection: close\r\n\r\n");
        }
        received.push(data.toString());
    });
    client.on("error", reject);
    client.on("end", () => {
        resolve(received.join(""));
    });
    return promise;
}
const BIG_DATA = Buffer.alloc(1024 * 64, "bun").toString();
describe("HTTP server CONNECT", () => {
    test("should work with proxy package", async () => {
        const env_1 = { stack: [], error: void 0, hasError: false };
        try {
            const targetServer = __addDisposableResource(env_1, http.createServer((req, res) => {
                res.end("Hello World from target server");
            }), true);
            const proxyServer = __addDisposableResource(env_1, createProxy(http.createServer()), true);
            let proxyHeaders = {};
            proxyServer.authenticate = req => {
                proxyHeaders = req.headers;
                return true;
            };
            await once(proxyServer.listen(0, "127.0.0.1"), "listening");
            await once(targetServer.listen(0, "127.0.0.1"), "listening");
            const proxyAddress = proxyServer.address();
            const targetAddress = targetServer.address();
            {
                // server should support http prefix but the proxy package it self does not
                // this behavior is consistent with node.js
                const response = await connectClient(proxyAddress, targetAddress, true);
                expect(proxyHeaders["proxy-authorization"]).toBe("Basic dXNlcjpwYXNzd29yZA==");
                expect(response).toContain("HTTP/1.1 404 Not Found");
            }
            {
                proxyHeaders = {};
                const response = await connectClient(proxyAddress, targetAddress, false);
                expect(proxyHeaders["proxy-authorization"]).toBe("Basic dXNlcjpwYXNzd29yZA==");
                expect(response).toContain("HTTP/1.1 200 OK");
                expect(response).toContain("Hello World from target server");
            }
        }
        catch (e_1) {
            env_1.error = e_1;
            env_1.hasError = true;
        }
        finally {
            const result_1 = __disposeResources(env_1);
            if (result_1)
                await result_1;
        }
    });
    test("should work with raw sockets", async () => {
        const env_2 = { stack: [], error: void 0, hasError: false };
        try {
            const proxyServer = __addDisposableResource(env_2, http.createServer((req, res) => {
                res.end("Hello World from proxy server");
            }), true);
            const targetServer = __addDisposableResource(env_2, http.createServer((req, res) => {
                res.end("Hello World from target server");
            }), true);
            let proxyHeaders = {};
            proxyServer.on("connect", (req, socket, head) => {
                proxyHeaders = req.headers;
                const [host, port] = req.url?.split(":") ?? [];
                const serverSocket = net.connect(parseInt(port), host, () => {
                    socket.write(`HTTP/1.1 200 Connection established\r\nConnection: close\r\n\r\n`);
                    serverSocket.pipe(socket);
                    socket.pipe(serverSocket);
                });
                serverSocket.on("error", err => {
                    socket.end("HTTP/1.1 502 Bad Gateway\r\n\r\n");
                });
                socket.on("error", err => {
                    serverSocket.destroy();
                });
                socket.on("end", () => serverSocket.end());
                serverSocket.on("end", () => socket.end());
            });
            await once(proxyServer.listen(0, "127.0.0.1"), "listening");
            const proxyAddress = proxyServer.address();
            await once(targetServer.listen(0, "127.0.0.1"), "listening");
            const targetAddress = targetServer.address();
            {
                const response = await connectClient(proxyAddress, targetAddress, false);
                expect(proxyHeaders["proxy-authorization"]).toBe("Basic dXNlcjpwYXNzd29yZA==");
                expect(response).toContain("HTTP/1.1 200 OK");
                expect(response).toContain("Hello World from target server");
            }
        }
        catch (e_2) {
            env_2.error = e_2;
            env_2.hasError = true;
        }
        finally {
            const result_2 = __disposeResources(env_2);
            if (result_2)
                await result_2;
        }
    });
    test("should handle multiple concurrent CONNECT requests", async () => {
        const env_3 = { stack: [], error: void 0, hasError: false };
        try {
            const proxyServer = __addDisposableResource(env_3, http.createServer((req, res) => {
                res.end("Hello World from proxy server");
            }), true);
            const targetServer = __addDisposableResource(env_3, http.createServer((req, res) => {
                res.end(`Response for ${req.url}`);
            }), true);
            let connectionCount = 0;
            proxyServer.on("connect", (req, socket, head) => {
                connectionCount++;
                const [host, port] = req.url?.split(":") ?? [];
                const serverSocket = net.connect(parseInt(port), host, () => {
                    socket.write(`HTTP/1.1 200 Connection established\r\n\r\n`);
                    serverSocket.pipe(socket);
                    socket.pipe(serverSocket);
                });
                serverSocket.on("error", () => socket.end("HTTP/1.1 502 Bad Gateway\r\n\r\n"));
                socket.on("error", () => serverSocket.destroy());
            });
            await once(proxyServer.listen(0, "127.0.0.1"), "listening");
            await once(targetServer.listen(0, "127.0.0.1"), "listening");
            const proxyAddress = proxyServer.address();
            const targetAddress = targetServer.address();
            // Create 5 concurrent connections
            const promises = Array.from({ length: 5 }, (_, i) => connectClient(proxyAddress, targetAddress, false));
            const results = await Promise.all(promises);
            expect(connectionCount).toBe(5);
            results.forEach(result => {
                expect(result).toContain("HTTP/1.1 200 OK");
            });
        }
        catch (e_3) {
            env_3.error = e_3;
            env_3.hasError = true;
        }
        finally {
            const result_3 = __disposeResources(env_3);
            if (result_3)
                await result_3;
        }
    });
    test("should handle CONNECT with invalid target", async () => {
        const env_4 = { stack: [], error: void 0, hasError: false };
        try {
            const proxyServer = __addDisposableResource(env_4, http.createServer((req, res) => {
                res.end("Hello World from proxy server");
            }), true);
            proxyServer.on("connect", (req, socket, head) => {
                const [host, port] = req.url?.split(":") ?? [];
                const serverSocket = net.connect(parseInt(port) || 80, host, () => {
                    socket.write(`HTTP/1.1 200 Connection established\r\n\r\n`);
                    serverSocket.pipe(socket);
                    socket.pipe(serverSocket);
                });
                serverSocket.on("error", err => {
                    socket.write("HTTP/1.1 502 Bad Gateway\r\n\r\n");
                    socket.end();
                });
                socket.on("error", () => serverSocket.destroy());
            });
            await once(proxyServer.listen(0, "127.0.0.1"), "listening");
            const proxyAddress = proxyServer.address();
            const client = net.connect(proxyAddress.port, proxyAddress.address, () => {
                client.write("CONNECT invalid.host.that.does.not.exist:9999 HTTP/1.1\r\nHost: invalid.host:9999\r\n\r\n");
            });
            const { promise, resolve } = Promise.withResolvers();
            const received = [];
            client.on("data", data => {
                received.push(data.toString());
            });
            client.on("end", () => {
                resolve(received.join(""));
            });
            const response = await promise;
            expect(response).toContain("502 Bad Gateway");
        }
        catch (e_4) {
            env_4.error = e_4;
            env_4.hasError = true;
        }
        finally {
            const result_4 = __disposeResources(env_4);
            if (result_4)
                await result_4;
        }
    });
    test("should handle CONNECT with authentication failure", async () => {
        const env_5 = { stack: [], error: void 0, hasError: false };
        try {
            const proxyServer = __addDisposableResource(env_5, http.createServer((req, res) => {
                res.end("Hello World from proxy server");
            }), true);
            proxyServer.on("connect", (req, socket, head) => {
                const auth = req.headers["proxy-authorization"];
                if (!auth || auth !== "Basic dXNlcjpwYXNzd29yZA==") {
                    socket.write("HTTP/1.1 407 Proxy Authentication Required\r\n");
                    socket.write('Proxy-Authenticate: Basic realm="Proxy"\r\n\r\n');
                    socket.end();
                    return;
                }
                socket.write("HTTP/1.1 200 Connection established\r\n\r\n");
                socket.end();
            });
            await once(proxyServer.listen(0, "127.0.0.1"), "listening");
            const proxyAddress = proxyServer.address();
            // Test without authentication
            const client1 = net.connect(proxyAddress.port, proxyAddress.address, () => {
                client1.write("CONNECT example.com:80 HTTP/1.1\r\nHost: example.com:80\r\n\r\n");
            });
            const { promise: promise1, resolve: resolve1 } = Promise.withResolvers();
            const received1 = [];
            client1.on("data", data => {
                received1.push(data.toString());
            });
            client1.on("end", () => {
                resolve1(received1.join(""));
            });
            const response1 = await promise1;
            expect(response1).toContain("407 Proxy Authentication Required");
            // Test with correct authentication
            const client2 = net.connect(proxyAddress.port, proxyAddress.address, () => {
                client2.write("CONNECT example.com:80 HTTP/1.1\r\nHost: example.com:80\r\nProxy-Authorization: Basic dXNlcjpwYXNzd29yZA==\r\n\r\n");
            });
            const { promise: promise2, resolve: resolve2 } = Promise.withResolvers();
            const received2 = [];
            client2.on("data", data => {
                received2.push(data.toString());
            });
            client2.on("end", () => {
                resolve2(received2.join(""));
            });
            const response2 = await promise2;
            expect(response2).toContain("200 Connection established");
        }
        catch (e_5) {
            env_5.error = e_5;
            env_5.hasError = true;
        }
        finally {
            const result_5 = __disposeResources(env_5);
            if (result_5)
                await result_5;
        }
    });
    test("should handle partial writes and buffering", async () => {
        const env_6 = { stack: [], error: void 0, hasError: false };
        try {
            const proxyServer = __addDisposableResource(env_6, http.createServer(), true);
            let bufferReceived = "";
            proxyServer.on("connect", (req, socket, head) => {
                socket.on("data", chunk => {
                    bufferReceived += chunk.toString();
                });
                // Send response in small chunks
                socket.write("HTTP/1.1 ");
                setTimeout(() => socket.write("200 "), 10);
                setTimeout(() => socket.write("Connection "), 20);
                setTimeout(() => socket.write("established\r\n\r\n"), 30);
                setTimeout(() => {
                    socket.write("Test data");
                    socket.end();
                }, 40);
            });
            await once(proxyServer.listen(0, "127.0.0.1"), "listening");
            const proxyAddress = proxyServer.address();
            const client = net.connect(proxyAddress.port, proxyAddress.address, () => {
                // Send request in chunks
                client.write("CONNECT example.com:80 ");
                setTimeout(() => client.write("HTTP/1.1\r\n"), 5);
                setTimeout(() => client.write("Host: example.com\r\n\r\n"), 10);
                setTimeout(() => client.write("Client data"), 35);
            });
            const { promise, resolve } = Promise.withResolvers();
            const received = [];
            client.on("data", data => {
                received.push(data.toString());
            });
            client.on("end", () => {
                resolve(received.join(""));
            });
            const response = await promise;
            expect(response).toContain("200 Connection established");
            expect(response).toContain("Test data");
            expect(bufferReceived).toContain("Client data");
        }
        catch (e_6) {
            env_6.error = e_6;
            env_6.hasError = true;
        }
        finally {
            const result_6 = __disposeResources(env_6);
            if (result_6)
                await result_6;
        }
    });
    test("should handle keep-alive connections", async () => {
        const env_7 = { stack: [], error: void 0, hasError: false };
        try {
            const proxyServer = __addDisposableResource(env_7, http.createServer(), true);
            const targetServer = __addDisposableResource(env_7, http.createServer((req, res) => {
                res.writeHead(200, { "Content-Length": "5" });
                res.end("Hello");
            }), true);
            proxyServer.on("connect", (req, socket, head) => {
                const [host, port] = req.url?.split(":") ?? [];
                const serverSocket = net.connect(parseInt(port), host, () => {
                    socket.write("HTTP/1.1 200 Connection established\r\n\r\n");
                    serverSocket.pipe(socket);
                    socket.pipe(serverSocket);
                });
                serverSocket.on("error", () => socket.end());
                socket.on("error", () => serverSocket.destroy());
            });
            await once(proxyServer.listen(0, "127.0.0.1"), "listening");
            await once(targetServer.listen(0, "127.0.0.1"), "listening");
            const proxyAddress = proxyServer.address();
            const targetAddress = targetServer.address();
            const client = net.connect(proxyAddress.port, proxyAddress.address, () => {
                client.write(`CONNECT ${targetAddress.address}:${targetAddress.port} HTTP/1.1\r\nHost: ${targetAddress.address}:${targetAddress.port}\r\n\r\n`);
            });
            const { promise, resolve } = Promise.withResolvers();
            const responses = [];
            let requestCount = 0;
            client.on("data", data => {
                const str = data.toString();
                responses.push(str);
                if (str.includes("200 Connection established") && requestCount === 0) {
                    // Send first request
                    client.write("GET /first HTTP/1.1\r\nHost: example.com\r\nConnection: keep-alive\r\n\r\n");
                    requestCount++;
                }
                else if (str.includes("Hello") && requestCount === 1) {
                    // Send second request on same connection
                    client.write("GET /second HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");
                    requestCount++;
                }
                else if (str.includes("Hello") && requestCount === 2) {
                    client.end();
                    resolve(responses);
                }
            });
            const allResponses = await promise;
            const combined = allResponses.join("");
            expect(combined).toContain("200 Connection established");
            expect(combined.match(/Hello/g)?.length).toBe(2);
        }
        catch (e_7) {
            env_7.error = e_7;
            env_7.hasError = true;
        }
        finally {
            const result_7 = __disposeResources(env_7);
            if (result_7)
                await result_7;
        }
    });
});
