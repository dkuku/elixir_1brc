defmodule OneBRC.MeasurementsProcessor.Version9.Worker do
  def run(parent_pid) do
    send(parent_pid, {:give_work, self()})

    receive do
      {:do_work, chunk} ->
        process_chunk(chunk)
        run(parent_pid)

      :result ->
        send(parent_pid, {:result, :erlang.get()})
    end
  end

  defp process_chunk(bin) do
    process_chunk_lines(bin)
  end

  defp process_chunk_lines(<<>>) do
    :ok
  end

  defp process_chunk_lines(bin) do
    parse_weather_station(bin, bin, 0)
  end

  defp parse_weather_station(bin, <<?;, _rest::binary>>, count) do
    <<key::binary-size(count), _, temp_bin::binary>> = bin
    parse_temp(temp_bin, String.to_atom(key))
  end

  defp parse_weather_station(bin, <<_c, rest::binary>>, count) do
    parse_weather_station(bin, rest, count + 1)
  end

  defp parse_weather_station(_bin, <<>>, _count) do
    :ok
  end

  # ex: 4.5
  defp parse_temp(<<?-, rest::binary>>, key) do
    parse_temp(rest, key, -1)
  end

  defp parse_temp(rest, key) do
    parse_temp(rest, key, 1)
  end

  defp parse_temp(<<_::4, d1::4, ?., _::4, d2::4, "\n", rest::binary>>, key, mult) do
    temp = mult * (d1 * 10 + d2)
    process_row(key, temp)
    process_chunk_lines(rest)
  end

  # ex: 45.3
  defp parse_temp(<<_::4, d1::4, _::4, d2::4, ?., _::4, d3::4, "\n", rest::binary>>, key, mult) do
    temp = mult * (d1 * 100 + d2 * 10 + d3)
    process_row(key, temp)
    process_chunk_lines(rest)
  end

  defp process_row(key, val) do
    existing_record = :erlang.get(key)

    case existing_record do
      :undefined ->
        :erlang.put(key, {1, val, val, val})

      {count, sum, min, max} ->
        :erlang.put(key, {count + 1, sum + val, min(min, val), max(max, val)})
    end
  end
end

defmodule OneBRC.MeasurementsProcessor.Version9 do
  @moduledoc """
  diff from version 7:
  1. removed :binary.split in process_chunk, using recursive parsing with pattern matching instead.

  Performance: Processes 10 million rows in approx 300ms
  """
  import OneBRC.MeasurementsProcessor
  alias OneBRC.MeasurementsProcessor.Version9.Worker

  require Logger

  def process(count) do
    t1 = System.monotonic_time(:millisecond)
    file_path = measurements_file(count)
    worker_count = System.schedulers_online()
    parent = self()

    wpids =
      Enum.map(1..worker_count, fn _ ->
        spawn_link(fn ->
          Worker.run(parent)
        end)
      end)

    {:ok, file} = :prim_file.open(file_path, [:raw, :binary, :read])
    :ok = read_and_process(file)
    :prim_file.close(file)

    results =
      wpids
      |> Enum.map(fn wpid ->
        send(wpid, :result)

        receive do
          {:result, result} -> result
        end
      end)

    t2 = System.monotonic_time(:millisecond)

    result =
      for outer <- results, {key, {count_1, sum_1, min_1, max_1}} <- outer, reduce: %{} do
        %{^key => {count_2, sum_2, min_2, max_2}} = acc ->
          Map.put(acc, key, {
            count_1 + count_2,
            sum_1 + sum_2,
            min(min_1, min_2),
            max(max_1, max_2)
          })

        acc ->
          Map.put(acc, key, {count_1, sum_1, min_1, max_1})
      end
      |> Enum.sort_by(fn {key, _} -> key end, :desc)

    t3 = System.monotonic_time(:millisecond)

    result_txt =
      result
      |> Enum.reduce([], fn {key, {count, sum, min, max}}, acc ->
        [
          to_string(key),
          ?;,
          to_string(min / 10.0),
          ?;,
          to_string(round_to_single_decimal(sum / count / 10.0)),
          ?;,
          to_string(max / 10.0),
          ?\n | acc
        ]
      end)

    t4 = System.monotonic_time(:millisecond)

    Logger.info("Processing data, stage 1 (processing) took: #{t2 - t1} ms")
    Logger.info("Processing data, stage 2 (aggregating) took: #{t3 - t2} ms")
    Logger.info("Processing data, stage 3 (sorting & txt creation) took: #{t4 - t3} ms")

    result_txt
  end

  defp read_and_process(file) do
    chunk_size = 1024 * 1024 * 1

    case :prim_file.read(file, chunk_size) do
      :eof ->
        :ok

      {:ok, data} ->
        data =
          case :prim_file.read_line(file) do
            {:ok, line} -> <<data::binary, line::binary>>
            :eof -> data
          end

        receive do
          {:give_work, worker_pid} ->
            send(worker_pid, {:do_work, data})
        end

        read_and_process(file)
    end
  end

  defp round_to_single_decimal(number) do
    round(number * 10) / 10.0
  end
end
