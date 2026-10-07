defmodule Transitmaps.Zip64Fixture do
  @moduledoc """
  Writes a zip whose entries all carry ZIP64 sizes, the way Munich's,
  Vienna's and Nice's feeds are packed: every size field reads 0xFFFFFFFF
  and the real sizes sit in each entry's ZIP64 extra field. OTP 27's `:zip`
  can't read such an archive.
  """

  @dos_date 0x21

  @doc "Writes `files` (`{name, contents}`) to `path` and returns it."
  def write!(path, files) do
    {locals, centrals, _offset} =
      Enum.reduce(files, {[], [], 0}, fn {name, contents}, {locals, centrals, offset} ->
        compressed = deflate(contents)
        crc = :erlang.crc32(contents)

        zip64 =
          <<1::little-16, 16::little-16, byte_size(contents)::little-64,
            byte_size(compressed)::little-64>>

        local =
          <<0x04034B50::little-32, 45::little-16, 0::little-16, 8::little-16, 0::little-16,
            @dos_date::little-16, crc::little-32, 0xFFFFFFFF::little-32, 0xFFFFFFFF::little-32,
            byte_size(name)::little-16, byte_size(zip64)::little-16>> <>
            name <> zip64 <> compressed

        central =
          <<0x02014B50::little-32, 45::little-16, 45::little-16, 0::little-16, 8::little-16,
            0::little-16, @dos_date::little-16, crc::little-32, 0xFFFFFFFF::little-32,
            0xFFFFFFFF::little-32, byte_size(name)::little-16, byte_size(zip64)::little-16,
            0::little-16, 0::little-16, 0::little-16, 0::little-32, offset::little-32>> <>
            name <> zip64

        {[local | locals], [central | centrals], offset + byte_size(local)}
      end)

    body = locals |> Enum.reverse() |> IO.iodata_to_binary()
    directory = centrals |> Enum.reverse() |> IO.iodata_to_binary()
    count = length(files)

    eocd =
      <<0x06054B50::little-32, 0::little-16, 0::little-16, count::little-16, count::little-16,
        byte_size(directory)::little-32, byte_size(body)::little-32, 0::little-16>>

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body <> directory <> eocd)
    path
  end

  defp deflate(data) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
    compressed = z |> :zlib.deflate(data, :finish) |> IO.iodata_to_binary()
    :zlib.close(z)
    compressed
  end
end
