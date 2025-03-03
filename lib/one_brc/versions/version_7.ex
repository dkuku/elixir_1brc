defmodule OneBRC.MeasurementsProcessor.Version7.Worker do
  def run(parent_pid) do
    send(parent_pid, {:give_work, self()})

    receive do
      {:do_work, chunk} ->
        process_chunk(chunk)
        run(parent_pid)

      :result ->
        send(parent_pid, {:result, :erlang.get()})
        # die
    end
  end

  defp process_chunk(bin) do
    :binary.split(bin, "\n", [:global])
    |> Enum.map(&parse_row/1)
    |> Enum.map(fn row ->
      process_row(row)
    end)
  end

  defp parse_row("") do
    nil
  end

  defp parse_row(row) do
    parse_row(row, row, 0)
  end

  defp parse_row(row, <<?;, _rest::binary>>, count) do
    # at this point, we know that count'th char is ;, so we can split the row using pattern matching
    <<city::binary-size(count), ?;, temp_value::binary>> = row
    [city, parse_temperature(temp_value)]
  end

  defp parse_row(row, <<_current_char, rest::binary>>, count) do
    parse_row(row, rest, count + 1)
  end

  # ex: -4.5
  defp parse_temperature(<<?-, d1, ?., d2, _::binary>>) do
    -(char_to_num(d1) * 10 + char_to_num(d2))
  end

  # ex: 4.5
  defp parse_temperature(<<d1, ?., d2, _::binary>>) do
    char_to_num(d1) * 10 + char_to_num(d2)
  end

  # ex: -45.3
  defp parse_temperature(<<?-, d1, d2, ?., d3, _::binary>>) do
    -(char_to_num(d1) * 100 + char_to_num(d2) * 10 + char_to_num(d3))
  end

  # ex: 45.3
  defp parse_temperature(<<d1, d2, ?., d3, _::binary>>) do
    char_to_num(d1) * 100 + char_to_num(d2) * 10 + char_to_num(d3)
  end

  defp char_to_num(char) do
    char - ?0
  end

  defp process_row(nil) do
    nil
  end

  defp process_row([key, val]) do
    existing_record = :erlang.get(key)

    new_record =
      case existing_record do
        :undefined ->
          {val, val, val, 1}

        {min, max, sum, count} ->
          min = if val < min, do: val, else: min
          max = if val > max, do: val, else: max
          new_c = count + 1
          new_sum = sum + val

          {min, max, new_sum, new_c}
      end

    :erlang.put(key, new_record)
  end
end

defmodule OneBRC.MeasurementsProcessor.Version7 do
  @moduledoc """
  diff from version 6:
  1. implements a fixed worker pool. This approach minimizes process creation/destruction overhead, as workers are reused
  2. removes some unnecessary enum.reduce calls by using process dictionary.
  3. removes using a common ets table for storing intermediate results, by using workers' process dictionary

  Performance: Processes 10 million rows in approx 400ms
  """
  import OneBRC.MeasurementsProcessor
  alias OneBRC.MeasurementsProcessor.Version7.Worker

  require Logger

  def process(count) do
    t1 = System.monotonic_time(:millisecond)
    file_path = measurements_file(count)
    worker_count = System.schedulers_online() * 2
    # boot up workers
    parent = self()

    wpids =
      Enum.map(1..worker_count, fn _ ->
        spawn_link(fn ->
          Worker.run(parent)
        end)
      end)

    {:ok, file} = :prim_file.open(file_path, [:raw, :binary, :read])
    :ok = read_and_process(file)

    # wait for all workers to finish
    Enum.map(1..worker_count, fn _ ->
      receive do
        {:give_work, _worker_pid} ->
          :ok
      end
    end)

    results =
      wpids
      |> Enum.map(fn wpid ->
        send(wpid, :result)
      end)
      |> Enum.map(fn _ ->
        receive do
          {:result, result} ->
            result
        end
      end)

    :prim_file.close(file)

    t2 = System.monotonic_time(:millisecond)

    result =
      results
      |> List.flatten()
      |> Enum.reduce(%{}, fn {key, {min_1, max_1, sum_1, count_1}}, acc ->
        existing_record = Map.get(acc, key, nil)

        new_record =
          case existing_record do
            nil ->
              {min_1, max_1, sum_1, count_1}

            {min_2, max_2, sum_2, count_2} ->
              min = if min_1 < min_2, do: min_1, else: min_2
              max = if max_1 > max_2, do: max_1, else: max_2
              new_c = count_1 + count_2
              sum = sum_1 + sum_2

              {min, max, sum, new_c}
          end

        Map.put(acc, key, new_record)
      end)
      |> Enum.map(fn {key, {min, max, sum, count}} ->
        # bring it back to floating point
        {key,
         %{
           min: round_to_single_decimal(min / 10.0),
           max: round_to_single_decimal(max / 10.0),
           mean: round_to_single_decimal(sum / count / 10.0)
         }}
      end)

    t3 = System.monotonic_time(:millisecond)

    result_txt =
      result
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.reduce("", fn {key, %{min: min, max: max, mean: mean}}, acc ->
        acc <> "#{key};#{min};#{mean};#{max}\n"
      end)

    t4 = System.monotonic_time(:millisecond)

    Logger.info("Processing data, stage 1 (processing) took: #{t2 - t1} ms")
    Logger.info("Processing data, stage 2 (aggregating) took: #{t3 - t2} ms")
    Logger.info("Processing data, stage 3 (sorting & txt creation) took: #{t4 - t3} ms")

    result_txt
  end

  defp read_and_process(file) do
    chunk_size = 1024 * 1024 * 1

    data =
      case :prim_file.read(file, chunk_size) do
        :eof ->
          nil

        {:ok, data} ->
          case :prim_file.read_line(file) do
            {:ok, line} ->
              <<data::binary, line::binary>>

            :eof ->
              data
          end
      end

    if !is_nil(data) do
      receive do
        {:give_work, worker_pid} ->
          send(worker_pid, {:do_work, data})
      end

      read_and_process(file)
    else
      :ok
    end
  end

  defp round_to_single_decimal(number) do
    round(number * 10) / 10.0
  end
end
