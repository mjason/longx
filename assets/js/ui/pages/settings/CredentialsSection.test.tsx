import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt } from "@/ui/test-utils";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import {
  createCredentialApiKey,
  createCredentialOauth2,
  credentialLoginUrl,
  deleteCredential,
  refreshCredential,
} from "@/ash_rpc";

describe("Settings → 凭证", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  test("lists every credential with its kind and status, never a value; shows the redirect URI", async () => {
    renderAt("/settings/credentials");
    const section = await screen.findByTestId("section-credentials");
    expect(await within(section).findByTestId("credentials-redirect-uri")).toHaveTextContent("/callback/credentials");
    const svc = await screen.findByTestId("credential-svc");
    expect(svc).toHaveTextContent("svc");
    expect(svc).toHaveTextContent("API Key");
    expect(within(svc).getByTestId("credential-status")).toHaveTextContent("就绪");
    expect(svc).toHaveTextContent("api.example.com");
    const coros = screen.getByTestId("credential-coros");
    expect(coros).toHaveTextContent("OAuth2");
    expect(within(coros).getByTestId("credential-status")).toHaveTextContent("待登录");
    // an API key has no login; an OAuth2 credential does
    expect(within(svc).queryByRole("button", { name: /登录/ })).toBeNull();
    expect(within(coros).getByRole("button", { name: /登录/ })).toBeInTheDocument();
  });

  test("adding an API key sends the name, the hosts split by line and the key", async () => {
    const user = userEvent.setup();
    renderAt("/settings/credentials");
    await screen.findByTestId("credential-svc");
    await user.click(screen.getByRole("button", { name: /添加 API Key/ }));
    const form = await screen.findByTestId("credential-form");
    await user.type(within(form).getByLabelText("名字"), "github");
    await user.type(within(form).getByLabelText("允许发送到的主机"), "api.github.com\nuploads.github.com");
    await user.type(within(form).getByLabelText("API Key / Token"), "ghp_secret");
    await user.click(within(form).getByRole("button", { name: "保存" }));
    await waitFor(() =>
      expect(createCredentialApiKey).toHaveBeenCalledWith(
        expect.objectContaining({
          input: { name: "github", allowedHosts: ["api.github.com", "uploads.github.com"], secret: "ghp_secret" },
        }),
      ),
    );
  });

  test("adding an OAuth2 client needs a client id or a registration URL; the client goes out with pkce", async () => {
    const user = userEvent.setup();
    renderAt("/settings/credentials");
    await screen.findByTestId("credential-svc");
    await user.click(screen.getByRole("button", { name: /添加 OAuth2/ }));
    const form = await screen.findByTestId("credential-form");
    await user.type(within(form).getByLabelText("名字"), "mcp");
    await user.type(within(form).getByLabelText("允许发送到的主机"), "mcp.example");
    await user.type(within(form).getByLabelText("授权地址（authorize URL）"), "https://mcp.example/authorize");
    await user.type(within(form).getByLabelText("令牌地址（token URL）"), "https://mcp.example/token");
    // nothing to log in with yet
    expect(within(form).getByRole("button", { name: "保存" })).toBeDisabled();
    await user.type(within(form).getByLabelText("动态注册地址（可选，RFC 7591）"), "https://mcp.example/register");
    await user.click(within(form).getByRole("button", { name: "保存" }));
    await waitFor(() =>
      expect(createCredentialOauth2).toHaveBeenCalledWith(
        expect.objectContaining({
          input: expect.objectContaining({
            name: "mcp",
            allowedHosts: ["mcp.example"],
            authorizeUrl: "https://mcp.example/authorize",
            tokenUrl: "https://mcp.example/token",
            registrationUrl: "https://mcp.example/register",
            pkce: true,
          }),
        }),
      ),
    );
  });

  test("登录 asks for the URL with this browser's origin and opens it; 立即刷新 and 删除 (behind a confirm) call their actions", async () => {
    const user = userEvent.setup();
    const open = vi.spyOn(window, "open").mockImplementation(() => null);
    vi.mocked(refreshCredential);
    renderAt("/settings/credentials");
    const coros = await screen.findByTestId("credential-coros");
    await user.click(within(coros).getByRole("button", { name: /登录/ }));
    await waitFor(() =>
      expect(credentialLoginUrl).toHaveBeenCalledWith(
        expect.objectContaining({ input: { id: "cred-coros", origin: window.location.origin } }),
      ),
    );
    await waitFor(() => expect(open).toHaveBeenCalledWith("https://auth.example/authorize?state=s1", "_blank", "noopener,noreferrer"));
    open.mockRestore();

    const svc = screen.getByTestId("credential-svc");
    await user.click(within(svc).getByRole("button", { name: /删除/ }));
    await user.click(await screen.findByRole("button", { name: "删除" }));
    await waitFor(() => expect(deleteCredential).toHaveBeenCalledWith(expect.objectContaining({ identity: "cred-svc" })));
  });
});
