import { configureTransport, transport } from "@/core/transport";
import { clearSession, loadSession, pairWithServer, saveSession, serverOrigin } from "./session";

// the app's one piece of state that outlives a launch: which server, which
// token — kept in the secure store, pushed into the core's transport
describe("session", () => {
  test("a bare host:port is an http origin; a scheme and a trailing slash are handled", () => {
    expect(serverOrigin("192.168.2.70:7788")).toBe("http://192.168.2.70:7788");
    expect(serverOrigin(" https://longx.example.com/ ")).toBe("https://longx.example.com");
    expect(serverOrigin("not a url")).toBeNull();
    expect(serverOrigin("")).toBeNull();
  });

  test("pairing posts the code and keeps the token; the transport is configured", async () => {
    const fetchMock = jest.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ token: "dev-token", device: { id: "d1", name: "Pixel", platform: "android" }, server: { version: "0.1.22" } }), { status: 200 }),
    );
    const session = await pairWithServer("192.168.2.70:7788", "483920", "Pixel");
    expect(fetchMock.mock.calls[0]![0]).toBe("http://192.168.2.70:7788/pair");
    expect(JSON.parse((fetchMock.mock.calls[0]![1] as RequestInit).body as string)).toEqual({ code: "483920", name: "Pixel", platform: expect.any(String) });
    expect(session).toEqual({ baseUrl: "http://192.168.2.70:7788", token: "dev-token", serverVersion: "0.1.22", deviceName: "Pixel" });
    expect(transport()).toMatchObject({ baseUrl: "http://192.168.2.70:7788", token: "dev-token" });
    // saved: a fresh load finds it and configures the transport again
    await saveSession(session);
    configureTransport({ baseUrl: "", token: null });
    expect(await loadSession()).toEqual(session);
    expect(transport().token).toBe("dev-token");
    await clearSession();
    expect(await loadSession()).toBeNull();
    fetchMock.mockRestore();
  });

  test("a wrong code is the server's words", async () => {
    jest.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({ error: "配对码不对或已过期" }), { status: 401 }));
    await expect(pairWithServer("10.0.0.5:7788", "000000", "Pixel")).rejects.toThrow("配对码不对或已过期");
  });
});
