defmodule Transitmaps.Realtime.GtfsRt do
  @moduledoc """
  Reads the trip updates out of a GTFS Realtime feed: which trips are
  running late or early, and which are cancelled.

  GTFS Realtime is a protocol buffer. Only the few fields a departure board
  needs are read, straight off the wire format, so no protobuf library or
  compiled schema is needed; every other field (vehicle positions, alerts,
  agency extensions) is skipped.

  https://gtfs.org/documentation/realtime/reference/
  """

  import Bitwise

  # TripDescriptor.schedule_relationship values that take a trip off the
  # timetable: CANCELED and DELETED.
  @cancelled [3, 7]
  # StopTimeUpdate.schedule_relationship
  @skipped 1
  @no_data 2

  @doc """
  The feed's trip updates, as maps of `trip_id`, `start_date` (or nil),
  `cancelled`, `delay` (the trip's own, or nil) and `stops`: each stop's
  `seq` and `stop_id` (either may be nil), `skipped`, `no_data`, and its
  `departure` and `arrival` as `{delay, time}` with either side nil.
  Raises on a binary that isn't a protocol buffer.
  """
  def trip_updates(binary) when is_binary(binary) do
    for {_trip_id, _start_date, update} <- index(binary), do: trip_update(update)
  end

  @doc """
  Each trip update's `{trip_id, start_date, binary}`, leaving the update
  itself to `trip_update/1`. A national feed carries tens of thousands of
  trips (Germany's is 18 MB) and a station shows a few, so each is read
  only when a station asks for it.
  """
  def index(binary) when is_binary(binary) do
    for {2, entity} <- fields(binary),
        {3, update} <- fields(entity),
        trip = update |> fields() |> first(1) |> trip_descriptor(),
        trip.trip_id != nil,
        do: {trip.trip_id, trip.start_date, update}
  end

  @doc "Reads one trip update found by `index/1`."
  def trip_update(binary) do
    fields = fields(binary)
    trip = fields |> first(1) |> trip_descriptor()

    %{
      trip_id: trip.trip_id,
      start_date: trip.start_date,
      cancelled: trip.relationship in @cancelled,
      delay: fields |> first(5) |> signed32(),
      stops: for({2, update} <- fields, do: stop_time_update(update))
    }
  end

  defp trip_descriptor(nil), do: %{trip_id: nil, start_date: nil, relationship: 0}

  defp trip_descriptor(binary) do
    fields = fields(binary)

    %{
      trip_id: first(fields, 1),
      start_date: first(fields, 3),
      relationship: first(fields, 4) || 0
    }
  end

  defp stop_time_update(binary) do
    fields = fields(binary)
    relationship = first(fields, 5) || 0

    %{
      seq: first(fields, 1),
      stop_id: first(fields, 4),
      arrival: fields |> first(2) |> stop_time_event(),
      departure: fields |> first(3) |> stop_time_event(),
      skipped: relationship == @skipped,
      no_data: relationship == @no_data
    }
  end

  defp stop_time_event(nil), do: nil

  defp stop_time_event(binary) do
    fields = fields(binary)

    case {fields |> first(1) |> signed32(), fields |> first(2) |> signed64()} do
      {nil, nil} -> nil
      event -> event
    end
  end

  defp first(fields, number) do
    Enum.find_value(fields, fn
      {^number, value} -> value
      _field -> nil
    end)
  end

  # int32 and int64 are sent as their 64-bit two's complement.
  defp signed32(nil), do: nil
  defp signed32(value) when is_integer(value), do: value |> band(0xFFFFFFFF) |> to_signed(32)
  defp signed64(nil), do: nil

  defp signed64(value) when is_integer(value),
    do: value |> band(0xFFFFFFFFFFFFFFFF) |> to_signed(64)

  defp to_signed(value, bits) do
    if value >= bsl(1, bits - 1), do: value - bsl(1, bits), else: value
  end

  # -- the wire format --------------------------------------------------------------

  @doc false
  # A message's fields in order, as `{number, value}`: an integer for
  # varint and fixed-width fields, a binary for length-delimited ones
  # (strings and nested messages alike).
  def fields(binary), do: fields(binary, [])

  defp fields(<<>>, acc), do: Enum.reverse(acc)

  defp fields(binary, acc) do
    {key, rest} = varint(binary)
    number = bsr(key, 3)

    case band(key, 7) do
      0 ->
        {value, rest} = varint(rest)
        fields(rest, [{number, value} | acc])

      1 ->
        <<value::little-64, rest::binary>> = rest
        fields(rest, [{number, value} | acc])

      2 ->
        {length, rest} = varint(rest)
        <<value::binary-size(length), rest::binary>> = rest
        fields(rest, [{number, value} | acc])

      5 ->
        <<value::little-32, rest::binary>> = rest
        fields(rest, [{number, value} | acc])

      type ->
        raise ArgumentError, "unsupported protobuf wire type #{type}"
    end
  end

  defp varint(binary), do: varint(binary, 0, 0)

  defp varint(<<1::1, bits::7, rest::binary>>, shift, acc) when shift < 64,
    do: varint(rest, shift + 7, bor(acc, bsl(bits, shift)))

  defp varint(<<0::1, bits::7, rest::binary>>, shift, acc), do: {bor(acc, bsl(bits, shift)), rest}

  defp varint(_binary, _shift, _acc), do: raise(ArgumentError, "truncated protobuf varint")

  @doc false
  # Encodes `{number, value}` fields, for tests: integers as varints
  # (negative ones as their 64-bit two's complement) and binaries as
  # length-delimited fields.
  def encode(fields) do
    for {number, value} <- fields, into: <<>> do
      case value do
        value when is_integer(value) ->
          encode_varint(bsl(number, 3)) <> encode_varint(band(value, 0xFFFFFFFFFFFFFFFF))

        value when is_binary(value) ->
          encode_varint(bor(bsl(number, 3), 2)) <> encode_varint(byte_size(value)) <> value
      end
    end
  end

  defp encode_varint(value) when value < 0x80, do: <<value>>
  defp encode_varint(value), do: <<bor(band(value, 0x7F), 0x80)>> <> encode_varint(bsr(value, 7))
end
