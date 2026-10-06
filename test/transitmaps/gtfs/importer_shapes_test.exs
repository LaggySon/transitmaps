defmodule Transitmaps.Gtfs.ImporterShapesTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Gtfs.Importer

  @moduletag :tmp_dir

  # Two winding shapes with enough points that simplification keeps some
  # and drops others, plus one the import doesn't want.
  defp rows do
    a = for i <- 1..40, do: {"A", 51.50 + i * 0.001, -0.20 + :math.sin(i / 3) * 0.002, i}
    b = for i <- 1..40, do: {"B", 51.60 + :math.cos(i / 4) * 0.002, -0.10 + i * 0.001, i}
    c = for i <- 1..10, do: {"C", 52.0, -1.0 + i * 0.01, i}
    {a, b, c}
  end

  defp write_shapes!(dir, rows) do
    body =
      Enum.map_join(rows, fn {id, lat, lon, seq} -> "#{id},#{lat},#{lon},#{seq}\n" end)

    File.write!(
      Path.join(dir, "shapes.txt"),
      "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence\n" <> body
    )
  end

  test "a packed line comes back exactly as it went in" do
    line = [[-0.1234567890123, 51.987654321], [179.99999999999997, -89.5]]
    assert line |> Importer.unpack_line() == line

    # Nothing is lost through the read: unpacking gives the same floats.
    assert Importer.unpack_line(<<1.5::float-64, -2.25::float-64>>) == [[1.5, -2.25]]
  end

  test "a shapes file that can't be read raises in the caller", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "shapes.txt"),
      "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence\nA,\"51.5,-0.2,1\n"
    )

    assert_raise NimbleCSV.ParseError, fn ->
      Importer.read_selected_shapes(dir, MapSet.new(["A"]))
    end
  end

  test "reads each shape's line the same whether its rows are grouped or not", %{tmp_dir: dir} do
    {a, b, c} = rows()
    selected = MapSet.new(["A", "B"])

    write_shapes!(dir, a ++ c ++ b)
    grouped = Importer.read_selected_shapes(dir, selected)

    # Out of order within a shape, and two shapes' rows interleaved.
    interleaved =
      Enum.zip(Enum.reverse(a), b)
      |> Enum.flat_map(fn {pa, pb} -> [pa, pb] end)
      |> Kernel.++(c)

    write_shapes!(dir, interleaved)
    assert Importer.read_selected_shapes(dir, selected) == grouped

    # A shape whose rows split around an unwanted shape's still reads whole.
    {a1, a2} = Enum.split(a, 20)
    write_shapes!(dir, a1 ++ c ++ a2 ++ b)
    assert Importer.read_selected_shapes(dir, selected) == grouped

    assert Map.keys(grouped) == ["A", "B"]
    line = Importer.unpack_line(grouped["A"].line)
    assert length(line) > 2 and length(line) < 40
    assert [[lon, lat] | _] = line
    assert lon == -0.20 + :math.sin(1 / 3) * 0.002 and lat == 51.50 + 0.001
  end
end
