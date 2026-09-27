defmodule Longx.Tls.SettingsTest do
  @moduledoc """
  What the HTTPS page saves: the names, the DNS provider and its variables
  (encrypted, never read back, only the provider's own names accepted —
  the tool runs with them in its environment), the CA, the port; and the
  request the tool is handed.
  """
  use Longx.DataCase, async: false

  alias Longx.Tls

  setup do
    dir = Path.join(System.tmp_dir!(), "longx-tls-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:longx, Longx.Tls, [])
    Application.put_env(:longx, Longx.Tls, Keyword.put(previous, :dir, dir))

    on_exit(fn ->
      Application.put_env(:longx, Longx.Tls, previous)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "nothing saved: off, Let's Encrypt, 7443, http redirected" do
    assert %{
             enabled: false,
             domains: [],
             provider: nil,
             directory: "letsencrypt",
             port: 7443,
             redirect: true,
             email: "",
             resolvers: [],
             propagation_check: true,
             propagation_wait: 60
           } = Tls.settings()

    assert Tls.env_names() == []
  end

  test "the DNS provider's variables are stored, named back but never shown" do
    assert {:ok, settings} =
             Tls.save(%{
               enabled: true,
               domains: [" LX.Example.com "],
               provider: "tencentcloud",
               env: %{
                 "TENCENTCLOUD_SECRET_ID" => "AKID123",
                 "TENCENTCLOUD_SECRET_KEY" => "s3cret"
               }
             })

    assert settings.domains == ["lx.example.com"]
    assert settings.provider == "tencentcloud"
    assert Tls.env_names() == ["TENCENTCLOUD_SECRET_ID", "TENCENTCLOUD_SECRET_KEY"]
    refute inspect(settings) =~ "s3cret"

    # an empty value keeps what is there, nil removes it
    assert {:ok, _} =
             Tls.save(%{env: %{"TENCENTCLOUD_SECRET_KEY" => "", "TENCENTCLOUD_TTL" => "120"}})

    assert %{"TENCENTCLOUD_SECRET_KEY" => "s3cret", "TENCENTCLOUD_TTL" => "120"} = Tls.env()

    assert {:ok, _} = Tls.save(%{env: %{"TENCENTCLOUD_TTL" => nil}})
    refute Map.has_key?(Tls.env(), "TENCENTCLOUD_TTL")

    # another provider: the old one's credentials go
    assert {:ok, _} = Tls.save(%{provider: "alidns", env: %{"ALICLOUD_ACCESS_KEY" => "a"}})
    assert Tls.env_names() == ["ALICLOUD_ACCESS_KEY"]
  end

  test "only the provider's own variables are accepted: the tool runs with them in its environment" do
    assert {:error, :env, message} =
             Tls.save(%{
               provider: "tencentcloud",
               env: %{"PATH" => "/tmp/evil", "LD_PRELOAD" => "x.so"}
             })

    assert message =~ "PATH"
    assert Tls.env_names() == []
  end

  test "every field is checked and the error names it" do
    for {attrs, field} <- [
          {%{domains: ["a b.test"]}, :domains},
          {%{provider: "no-such-dns"}, :provider},
          {%{port: 0}, :port},
          {%{port: 70_000}, :port},
          {%{directory: "ftp://ca.test/dir"}, :directory},
          {%{email: "not an address"}, :email},
          {%{enabled: true}, :domains}
        ] do
      assert {:error, ^field, _message} = Tls.save(attrs),
             "#{inspect(attrs)} should fail on #{field}"
    end

    # the page's own http port is not the https one
    http_port = LongxWeb.Endpoint.config(:http)[:port]
    assert {:error, :port, _} = Tls.save(%{port: http_port})

    # enabling needs the names and a provider
    assert {:error, :provider, _} = Tls.save(%{enabled: true, domains: ["lx.example.com"]})

    assert {:ok, %{directory: "letsencrypt-staging", port: 8443}} =
             Tls.save(%{directory: "letsencrypt-staging", port: 8443})

    assert {:ok, %{directory: "https://ca.test/dir"}} =
             Tls.save(%{directory: "https://ca.test/dir"})
  end

  test "the providers are the pinned tool's catalog, with a code, name and variables" do
    providers = Tls.providers()
    assert length(providers) > 150

    assert %{name: "Tencent Cloud DNS", credentials: credentials, additional: additional} =
             Enum.find(providers, &(&1.code == "tencentcloud"))

    assert Enum.map(credentials, & &1.name) == [
             "TENCENTCLOUD_SECRET_ID",
             "TENCENTCLOUD_SECRET_KEY"
           ]

    assert Enum.any?(additional, &(&1.name == "TENCENTCLOUD_TTL"))
    assert Tls.provider("rfc2136").code == "dnsupdate"
    assert Tls.provider("nope") == nil
  end

  test "the request handed to the tool: the settings, the variables, the account" do
    {:ok, _} =
      Tls.save(%{
        enabled: true,
        domains: ["lx.example.com"],
        provider: "tencentcloud",
        email: "me@example.com",
        directory: "letsencrypt-staging",
        env: %{"TENCENTCLOUD_SECRET_ID" => "id", "TENCENTCLOUD_SECRET_KEY" => "key"}
      })

    request = Tls.request()

    assert %{
             "directory" => "letsencrypt-staging",
             "domains" => ["lx.example.com"],
             "provider" => "tencentcloud",
             "email" => "me@example.com",
             "env" => %{"TENCENTCLOUD_SECRET_ID" => "id", "TENCENTCLOUD_SECRET_KEY" => "key"},
             "account" => nil
           } = request

    account = %{"directory" => "https://ca/dir", "key" => "PEM", "uri" => "https://ca/acct/1"}
    :ok = Tls.store_account(account)
    assert Tls.request()["account"] == account
  end

  test "a certificate is stored as files, the key readable by the owner alone", ctx do
    result = %{
      "certificate" => "-----BEGIN CERTIFICATE-----\nleaf\n-----END CERTIFICATE-----\n",
      "private_key" => "-----BEGIN EC PRIVATE KEY-----\nk\n-----END EC PRIVATE KEY-----\n",
      "issuer" => "-----BEGIN CERTIFICATE-----\nca\n-----END CERTIFICATE-----\n",
      "domains" => ["lx.example.com"],
      "not_before" => "2026-09-27T00:00:00Z",
      "not_after" => "2026-12-26T00:00:00Z",
      "serial" => "abc123",
      "account" => %{"directory" => "https://ca/dir", "key" => "PEM", "uri" => "u"}
    }

    assert :ok = Tls.store_certificate(result)
    assert File.read!(Path.join(ctx.dir, "cert.pem")) == result["certificate"]
    assert File.read!(Path.join(ctx.dir, "key.pem")) == result["private_key"]
    assert %File.Stat{mode: mode} = File.stat!(Path.join(ctx.dir, "key.pem"))
    assert Bitwise.band(mode, 0o077) == 0

    assert %{
             domains: ["lx.example.com"],
             not_after: %DateTime{year: 2026, month: 12, day: 26},
             serial: "abc123"
           } = Tls.certificate()

    # the account comes back with the next request
    assert Tls.request()["account"]["uri"] == "u"
  end

  test "this machine's addresses for the A record: the LAN first; loopback, down and virtual bridges left out" do
    interfaces = [
      {~c"lo",
       [flags: [:up, :loopback, :running], addr: {127, 0, 0, 1}, addr: {10, 255, 255, 254}]},
      {~c"eth0", [flags: [:up, :broadcast, :running], addr: {172, 25, 0, 1}]},
      {~c"eth1", [flags: [:up, :broadcast, :running], addr: {192, 168, 2, 129}]},
      {~c"docker0", [flags: [:up, :broadcast], addr: {172, 17, 0, 1}]},
      {~c"br-b1366aa03e5e", [flags: [:up, :broadcast], addr: {172, 18, 0, 1}]},
      {~c"veth0a1b", [flags: [:up], addr: {169, 254, 3, 4}]},
      {~c"eth2", [flags: [:broadcast], addr: {192, 168, 9, 9}]},
      {~c"wlan0", [flags: [:up, :broadcast, :running], addr: {10, 0, 0, 7}]},
      {~c"tailscale0", [flags: [:up, :running], addr: {100, 101, 102, 103}]}
    ]

    assert Tls.pick_addresses(interfaces) == [
             "192.168.2.129",
             "10.0.0.7",
             "172.25.0.1",
             "100.101.102.103"
           ]
  end

  describe "a fake-ip DNS on this machine" do
    setup do
      previous = Application.get_env(:longx, Longx.Tls)
      on_exit(fn -> Application.put_env(:longx, Longx.Tls, previous) end)
      :ok
    end

    defp lookups(system, public \\ %{}) do
      {_pid, port} = Longx.Test.FakeDns.start(public)

      Application.put_env(
        :longx,
        Longx.Tls,
        Keyword.merge(Application.get_env(:longx, Longx.Tls),
          system_lookup: fn _ -> system end,
          public_dns: [{{127, 0, 0, 1}, port}]
        )
      )

      port
    end

    test "the resolvers for the TXT check are IP addresses, with :53 unless a port is given" do
      assert {:ok, %{resolvers: resolvers}} =
               Tls.save(%{
                 resolvers: [
                   " 223.5.5.5 ",
                   "119.29.29.29:5353",
                   "[2400:3200::1]:53",
                   "2400:3200::1"
                 ]
               })

      # the same resolver twice is kept once
      assert resolvers == ["223.5.5.5:53", "119.29.29.29:5353", "[2400:3200::1]:53"]
      assert {:error, :resolvers, message} = Tls.save(%{resolvers: ["dns.example.com"]})
      assert message =~ "IP"
      assert {:error, :propagation_wait, _} = Tls.save(%{propagation_wait: 5_000})
      assert {:error, :propagation_check, _} = Tls.save(%{propagation_check: "no"})
    end

    test "the TXT check goes to the public resolvers when this machine's answer is a proxy's",
         _ctx do
      port = lookups(["198.18.0.7"])
      {:ok, _} = Tls.save(%{domains: ["lx.example.test"], provider: "tencentcloud"})
      assert Tls.request()["resolvers"] == ["127.0.0.1:#{port}"]

      # a real answer: the machine's own resolver
      lookups(["192.168.2.70"])
      assert Tls.request()["resolvers"] == []

      # the person's own list wins either way
      lookups(["198.18.0.7"])
      {:ok, _} = Tls.save(%{resolvers: ["1.1.1.1"]})
      assert Tls.request()["resolvers"] == ["1.1.1.1:53"]
    end

    test "no check, a wait instead, when the person turns it off" do
      lookups(["192.168.2.70"])

      {:ok, _} =
        Tls.save(%{
          domains: ["lx.example.test"],
          provider: "tencentcloud",
          propagation_check: false,
          propagation_wait: 90
        })

      assert %{"propagation_check" => false, "propagation_wait_s" => 90} = Tls.request()
      {:ok, _} = Tls.save(%{propagation_check: true})
      refute Map.has_key?(Tls.request(), "propagation_check")
    end

    test "where a name points: the public answer, this machine's beside it, a proxy's marked" do
      here = List.first(Tls.local_addresses()) || "192.0.2.1"

      port =
        lookups(["198.18.0.7"], %{"lx.example.test" => here, "other.example.test" => "192.0.2.99"})

      assert %{
               fake_ip: true,
               check_resolvers: ["127.0.0.1:" <> _],
               resolution: [
                 %{
                   domain: "lx.example.test",
                   addresses: [^here],
                   local: ["198.18.0.7"],
                   fake_ip: true
                 },
                 %{domain: "other.example.test", addresses: ["192.0.2.99"], here: false},
                 %{domain: "nowhere.example.test", addresses: []}
               ]
             } =
               Tls.resolution_report([
                 "lx.example.test",
                 "other.example.test",
                 "nowhere.example.test",
                 "*.lx.example.test"
               ])

      assert port > 0
    end
  end
end
