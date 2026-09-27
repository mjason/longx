defmodule Longx.Test.Certs do
  @moduledoc """
  Throwaway TLS certificates for tests (OTP's `:public_key.pkix_test_data/1`):
  a leaf and its key as PEM, and the leaf's serial. Every call makes a new
  one.
  """

  @spec self_signed() :: %{cert: String.t(), key: String.t(), serial: integer, der: binary}
  def self_signed do
    curve = {:namedCurve, :secp256r1}

    # sha256: the default digest leaves TLS 1.3 without an acceptable
    # signature ("unable_to_supply_acceptable_cert")
    %{server_config: server} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: [key: curve, digest: :sha256], peer: [key: curve, digest: :sha256]},
        client_chain: %{root: [key: curve, digest: :sha256], peer: [key: curve, digest: :sha256]}
      })

    der = Keyword.fetch!(server, :cert)
    {:ECPrivateKey, key_der} = Keyword.fetch!(server, :key)

    %{
      cert: :public_key.pem_encode([{:Certificate, der, :not_encrypted}]),
      key: :public_key.pem_encode([{:ECPrivateKey, key_der, :not_encrypted}]),
      serial: serial(der),
      der: der
    }
  end

  @doc "The serial number of a DER certificate."
  @spec serial(binary) :: integer
  def serial(der) do
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :otp)
    elem(tbs, 2)
  end

  @doc "The serial of the certificate a TLS server at `port` presents to a new connection."
  @spec served_serial(:inet.port_number()) :: integer
  def served_serial(port) do
    {:ok, socket} =
      :ssl.connect(~c"127.0.0.1", port, [verify: :verify_none, active: false], 5_000)

    {:ok, der} = :ssl.peercert(socket)
    :ssl.close(socket)
    serial(der)
  end
end
