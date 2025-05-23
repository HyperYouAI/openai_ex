defmodule OpenaiEx.HttpSse do
  @moduledoc false
  alias OpenaiEx.Http.Finch, as: Client
  alias OpenaiEx.Error
  require Logger

  # based on
  # https://gist.github.com/zachallaun/88aed2a0cef0aed6d68dcc7c12531649
  # and
  # https://html.spec.whatwg.org/multipage/server-sent-events.html#parsing-an-event-stream

  def post(openai = %OpenaiEx{}, url, json: json) do
    me = self()
    ref = make_ref()
    task = Task.async(fn -> finch_stream(openai, url, json, me, ref) end)
    status = receive(do: ({:chunk, {:status, status}, ^ref} -> status))
    headers = receive(do: ({:chunk, {:headers, headers}, ^ref} -> headers))

    if status in 200..299 do
      stream_receiver = create_stream_receiver(ref, openai.stream_timeout)
      body_stream = Stream.resource(&init_stream/0, stream_receiver, end_stream(task))
      {:ok, %{status: status, headers: headers, body_stream: body_stream, task_pid: task.pid}}
    else
      body = extract_error(ref, "") |> Jason.decode!()
      Task.shutdown(task)
      {:error, Error.status_error(status, %{status: status, headers: headers, body: body}, body)}
    end
  end

  def cancel_request(task_pid) when is_pid(task_pid) do
    send(task_pid, :cancel_request)
  end

  defp finch_stream(openai = %OpenaiEx{}, url, json, me, ref) do
    request = Client.build_post(openai, url, json: json)
    send_me_chunk = create_chunk_sender(me, ref)

    try do
      Client.stream(request, openai, send_me_chunk)
      send(me, {:done, ref})
    catch
      :throw, :cancel_request -> {:exception, :cancel_request}
    end
  end

  defp create_chunk_sender(me, ref) do
    fn chunk, _acc ->
      receive do
        :cancel_request ->
          send(me, {:canceled, ref})
          throw(:cancel_request)
      after
        0 -> send(me, {:chunk, chunk, ref})
      end
    end
  end

  defp init_stream, do: ""

  defp create_stream_receiver(ref, timeout) do
    fn acc when is_binary(acc) ->
      receive do
        {:chunk, {:data, evt_data}, ^ref} ->
          {events, next_acc} = extract_events(evt_data, acc)
          {[events], next_acc}

        # some 3rd party providers seem to be ending the stream with eof,
        # rather than 2 line terminators. Hopefully those will be fixed and this
        # can be removed in the future
        {:done, ^ref} when acc == "data: [DONE]" ->
          Logger.warning("\"data: [DONE]\" should be followed by 2 line terminators")
          {:halt, acc}

        {:done, ^ref} ->
          {:halt, acc}

        {:canceled, ^ref} ->
          Logger.info("Request canceled by user")
          {:halt, {:exception, :canceled}}
      after
        timeout ->
          Logger.warning("Stream timeout after #{timeout}ms")
          {:halt, {:exception, :timeout}}
      end
    end
  end

  defp end_stream(task) do
    fn acc ->
      try do:
            (case acc do
               {:exception, :timeout} -> raise(Error.sse_timeout_error())
               {:exception, :canceled} -> raise(Error.sse_user_cancellation())
               _ -> :ok
             end),
          after: Task.shutdown(task)
    end
  end

  @double_eol ~r/(\r?\n|\r){2}/
  @double_eol_eos ~r/(\r?\n|\r){2}$/

  defp extract_events(evt_data, acc) do
    all_data = acc <> evt_data

    if Regex.match?(@double_eol, all_data) do
      {remaining, lines} = extract_lines(all_data)
      events = process_fields(lines)
      {events, remaining}
    else
      {[], all_data}
    end
  end

  defp extract_lines(data) do
    lines = String.split(data, @double_eol)
    incomplete_line = !Regex.match?(@double_eol_eos, data)
    if incomplete_line, do: lines |> List.pop_at(-1), else: {"", lines}
  end

  defp process_fields(lines) do
    lines
    |> Enum.map(&extract_field/1)
    |> Enum.filter(&data?/1)
    |> Enum.map(&to_json/1)
  end

  defp to_json(field) do
    case field do
      %{data: data} ->
        %{data: Jason.decode!(data)}

      %{eventType: value} ->
        [event_id, data] = String.split(value, "\ndata: ", parts: 2)
        %{event: event_id, data: Jason.decode!(data)}
    end
  end

  defp data?(field) do
    case field do
      %{data: "[DONE]"} -> false
      %{data: _} -> true
      %{eventType: "done\ndata: [DONE]"} -> false
      %{eventType: _} -> true
      _ -> false
    end
  end

  defp extract_field(line) do
    [name | rest] = String.split(line, ":", parts: 2)
    value = Enum.join(rest, "") |> String.replace_prefix(" ", "")

    case name do
      "data" -> %{data: value}
      "event" -> %{eventType: value}
      "id" -> %{lastEventId: value}
      "retry" -> %{retry: value}
      _ -> nil
    end
  end

  defp extract_error(ref, acc) do
    receive do
      {:chunk, {:data, chunk}, ^ref} -> extract_error(ref, acc <> chunk)
      {:done, ^ref} -> acc
    end
  end
end
