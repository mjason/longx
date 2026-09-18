defmodule Longx.Agent.Definition.Lint do
  @moduledoc """
  A few things a project's plug should never do itself now that the kernel
  does them — matched in the source text when a layer loads, reported as a
  *notice* in front of the model (never an error: the plug still runs).

  The case that motivated it: an agent wrote a plug that listened on a
  loopback port for an OAuth redirect, kept tokens in a JSON file and
  wrote a knowledge doc saying that was the only way; every later session
  read the doc, found the tool and followed it, while `Longx.Credentials`
  (a login through Longx's own callback, tokens encrypted and refreshed)
  sat unused in the same prompt. A notice next to the tool is what turns
  "the agent found a tool" into "the agent migrates the tool".
  """

  @checks [
    {~r/:gen_tcp\.listen|:ssl\.listen|Plug\.Cowboy|Bandit\.start_link|:httpd\.start/,
     "listens on a port (an OAuth redirect?)"},
    {~r/System\.get_env\(\s*"[^"]*(KEY|SECRET|TOKEN|PASSWORD)[^"]*"/i,
     "reads a key from the environment"},
    {~r/(token|oauth|credential)s?\.json|refresh_token/i, "keeps tokens in a file"}
  ]

  @doc "The notices a plug file earns, none for a clean one."
  @spec check(Path.t(), String.t()) :: [String.t()]
  def check(path, source) when is_binary(path) and is_binary(source) do
    case for {re, why} <- @checks, Regex.match?(re, source), do: why do
      [] ->
        []

      reasons ->
        [
          "⚠ The plug #{Path.basename(path)} handles secrets on its own (it #{Enum.join(reasons, ", ")}). " <>
            "Longx.Credentials already keeps API keys and OAuth2 tokens encrypted, refreshes them and completes a login through Longx's own /callback/credentials: " <>
            "migrate it — declare the credential with credential_create (an OAuth2 client registers itself with registration_url), log in with credential_login, " <>
            "call the API with http_request or, from the plug's own code, Longx.Credentials.request/4 — then delete the old login tool and its token file, " <>
            "and rewrite the knowledge doc that describes the old way (a local doc never outranks what Longx ships)."
        ]
    end
  end
end
