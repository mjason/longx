import { afterEach, describe, expect, test } from "vitest";
import { authHeaders, configureTransport, resetTransport, socketUrl, transportUrl } from "./transport";

// the browser talks to its own origin with the page's CSRF token; a native
// app names the server and carries its device token instead
describe("transport", () => {
  afterEach(() => {
    resetTransport();
    document.head.innerHTML = "";
  });

  test("the browser: relative paths, the CSRF token from the page, the socket at /socket", () => {
    document.head.innerHTML = '<meta name="csrf-token" content="tok-1">';
    expect(transportUrl("/rpc/run")).toBe("/rpc/run");
    expect(authHeaders()).toEqual({ "X-CSRF-Token": "tok-1" });
    expect(socketUrl()).toBe("/socket");
  });

  test("a native app: absolute URLs on the configured server, a bearer, the socket as ws(s)", () => {
    configureTransport({ baseUrl: "http://192.168.2.70:7788/", token: "dev-token" });
    expect(transportUrl("/rpc/run")).toBe("http://192.168.2.70:7788/rpc/run");
    expect(authHeaders()).toEqual({ Authorization: "Bearer dev-token" });
    expect(socketUrl()).toBe("ws://192.168.2.70:7788/socket");
    configureTransport({ baseUrl: "https://longx.example.com" });
    expect(socketUrl()).toBe("wss://longx.example.com/socket");
  });
});
