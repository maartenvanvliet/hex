defmodule Hex.SCM do
  @moduledoc false

  @behaviour Mix.SCM
  @packages_dir "packages"

  def fetchable? do
    true
  end

  def format(_opts) do
    "Hex package"
  end

  def format_lock(opts) do
    case opts[:lock] do
      {:package, version} ->
        version
      {:hex, name, version} ->
        "#{version} (#{name})"
      _ ->
        nil
    end
  end

  def accepts_options(name, opts) do
    Keyword.put_new(opts, :hex, name)
  end

  def checked_out?(opts) do
    File.dir?(opts[:dest])
  end

  def lock_status(opts) do
    case opts[:lock] do
      # Support everything pre Hex 0.6.0 (2014-10-13)
      {:package, version} ->
        lock_status(opts[:dest], nil, version)
      {:hex, name, version} ->
        lock_status(opts[:dest], Atom.to_string(name), version)
      nil ->
        :mismatch
      _ ->
        :outdated
    end
  end

  defp lock_status(dest, name, version) do
    case File.read(Path.join(dest, ".hex")) do
      {:ok, file} ->
        manifest = parse_manifest(file)

        # Support everything pre Hex 0.6.0 (2014-10-13)
        if name == nil do
          manifest = put_elem(manifest, 0, nil)
        end

        if {name, version} == manifest do
          :ok
        else
          :mismatch
        end

      {:error, _} ->
        :mismatch
    end
  end


  def equal?(opts1, opts2) do
    opts1[:hex] == opts2[:hex]
  end

  def checkout(opts) do
    Hex.Util.move_home

    {_name, version} = get_lock(opts[:lock])
    name     = opts[:hex]
    dest     = opts[:dest]
    filename = "#{name}-#{version}.tar"
    path     = cache_path(filename)
    url      = Hex.API.cdn_url("tarballs/#{filename}")

    Mix.shell.info("Checking package (#{url})")

    case Hex.Parallel.await(:hex_fetcher, {name, version}) do
      {:ok, :cached} ->
        Mix.shell.info("Using locally cached package")
      {:ok, :new} ->
        Mix.shell.info("Fetched package")
      {:error, reason} ->
        Mix.shell.error(reason)
        unless File.exists?(path) do
          Mix.raise "Package fetch failed and no cached copy available"
        end
        Mix.shell.info("Check failed. Using locally cached package")
    end

    File.rm_rf!(dest)
    Hex.Tar.unpack(path, dest, {name, version})
    manifest = encode_manifest(name, version)
    File.write!(Path.join(dest, ".hex"), manifest)

    Mix.shell.info("Unpacked package tarball (#{path})")
    opts[:lock]
  end

  def update(opts) do
    checkout(opts)
  end

  defp get_lock(lock) do
    case lock do
      # Support everything pre Hex 0.6.0 (2014-10-13)
      {:package, version} -> {nil, version}
      {:hex, name, version} -> {name, version}
    end
  end

  defp parse_manifest(file) do
    contents = file |> String.strip |> String.split(",")

    case contents do
      [name, version] ->
        {name, version}
      [version] ->
        {nil, version}
    end
  end

  defp encode_manifest(name, version) do
    "#{name},#{version}"
  end

  defp cache_path do
    Path.join(Hex.home, @packages_dir)
  end

  defp cache_path(name) do
    Path.join([Hex.home, @packages_dir, name])
  end

  def prefetch(lock) do
    fetch = fetch_from_lock(lock)

    Enum.each(fetch, fn {name, version} ->
      Hex.Parallel.run(:hex_fetcher, {name, version}, fn ->
        filename = "#{name}-#{version}.tar"
        path = cache_path(filename)
        fetch(filename, path)
      end)
    end)
  end

  defp fetch_from_lock(lock) do
    deps_path = Mix.Project.deps_path

    Enum.flat_map(lock, fn entry ->
      case entry do
        # Support everything pre Hex 0.6.0 (2014-10-13)
        {app, {:package, version}} ->
          name = app
          version = version
        {_app, {:hex, name, version}} ->
          name = name
          version = version
        _ ->
          :ok
      end

      if name && fetch?(name, version, deps_path) do
        [{name, version}]
      else
        []
      end
    end)
  end

  defp fetch?(name, version, deps_path) do
    dest = Path.join(deps_path, "#{name}")

    case File.read(Path.join(dest, ".hex")) do
      {:ok, contents} ->
        {name, version} != parse_manifest(contents)
      {:error, _} ->
        true
    end
  end

  defp fetch(name, path) do
    etag = Hex.Util.etag(path)
    url  = Hex.API.cdn_url("tarballs/#{name}")
    File.mkdir_p!(cache_path)

    case request(url, etag) do
      {:ok, body} when is_binary(body) ->
        File.write!(path, body)
        {:ok, :new}
      other ->
        other
    end
  end

  defp request(url, etag) do
    opts = [body_format: :binary]
    headers = [{'user-agent', Hex.API.user_agent}]
    if etag do
      headers = headers ++ [{'if-none-match', etag}]
    end

    http_opts = [ssl: Hex.API.ssl_opts()]
    case :httpc.request(:get, {url, headers}, http_opts, opts, :hex) do
      {:ok, {{_version, 200, _reason}, _headers, body}} ->
        {:ok, body}
      {:ok, {{_version, 304, _reason}, _headers, _body}} ->
        {:ok, :cached}
      {:ok, {{_version, code, _reason}, _headers, _body}} ->
        {:error, "Request failed (#{code})"}
      {:error, reason} ->
        {:error, "Request failed: #{inspect reason}"}
    end
  end
end
