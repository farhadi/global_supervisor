defmodule GlobalSupervisor do
  @moduledoc """
  A supervisor that dynamically distributes children across all GlobalSupervisors
  registered with the same name in the cluster.
  """
  @behaviour GenServer

  @doc """
  Callback invoked to start the supervisor and during hot code upgrades.

  Developers typically invoke `GlobalSupervisor.init/1` at the end of
  their init callback to return the proper supervision flags.
  """
  @callback init(init_arg :: term) :: {:ok, sup_flags()} | :ignore

  @typedoc "The supervisor flags returned on init"
  @type sup_flags() :: %{
          strategy: strategy(),
          intensity: non_neg_integer(),
          period: pos_integer(),
          max_children: non_neg_integer() | :infinity,
          extra_arguments: [term()],
          auto_balance: boolean(),
          locator: (tuple(), [atom()] -> atom())
        }

  @typedoc "Options given to `start_link/2` and `init/1`"
  @type init_option ::
          {:strategy, strategy()}
          | {:max_restarts, non_neg_integer()}
          | {:max_seconds, pos_integer()}
          | {:max_children, non_neg_integer() | :infinity}
          | {:extra_arguments, [term()]}
          | {:auto_balance, boolean()}
          | {:locator, (tuple(), [atom()] -> atom())}

  @typedoc "Supported strategies"
  @type strategy :: :one_for_one

  # In this struct, `args` refers to the arguments passed to init/1 (the `init_arg`).
  defstruct [
    :args,
    :extra_arguments,
    :mod,
    :name,
    :strategy,
    :max_children,
    :max_restarts,
    :max_seconds,
    :auto_balance,
    :locator,
    children: %{},
    restarts: [],
    nephews: %{}
  ]

  @doc """
  Returns a specification to start a global supervisor under a supervisor.

  See `Supervisor`.
  """
  def child_spec(opts) when is_list(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc false
  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      @behaviour GlobalSupervisor
      if Module.get_attribute(__MODULE__, :doc) == nil do
        @doc """
        Returns a specification to start this module under a supervisor.

        See `Supervisor`.
        """
      end

      def child_spec(arg) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [arg]},
          type: :supervisor
        }

        Supervisor.child_spec(default, unquote(Macro.escape(opts)))
      end

      defoverridable child_spec: 1
    end
  end

  def start_link(options) when is_list(options) do
    keys = [
      :extra_arguments,
      :max_children,
      :max_seconds,
      :max_restarts,
      :strategy,
      :auto_balance,
      :locator
    ]

    {sup_opts, start_opts} = Keyword.split(options, keys)
    start_link(Supervisor.Default, init(sup_opts), start_opts)
  end

  def start_link(mod, init_arg, opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {mod, init_arg, opts[:name]}, opts)
  end

  defdelegate start_child(supervisor, child_spec), to: DynamicSupervisor

  def rebalance(supervisor) do
    GenServer.cast(supervisor, :rebalance)
  end

  def locate(child_spec, nodes) do
    index = :erlang.phash2(child_spec, Enum.count(nodes))
    Enum.at(nodes, index)
  end

  defp nodes(%{nephews: nephews}) do
    nephews
    |> Map.keys()
    |> List.insert_at(0, node())
    |> Enum.sort()
  end

  @spec init([init_option]) :: {:ok, sup_flags()}
  def init(options) when is_list(options) do
    {:ok, flags} = DynamicSupervisor.init(options)

    auto_balance = Keyword.get(options, :auto_balance, true)
    locator = Keyword.get(options, :locator, &__MODULE__.locate/2)

    flags =
      flags
      |> Map.put(:auto_balance, auto_balance)
      |> Map.put(:locator, locator)

    {:ok, flags}
  end

  ## Callbacks

  @impl true
  def init({mod, init_arg, name}) do
    unless is_atom(name) do
      raise ArgumentError, "expected :name option to be an atom"
    end

    Process.put(:"$initial_call", {:supervisor, mod, 1})
    Process.flag(:trap_exit, true)

    case mod.init(init_arg) do
      {:ok, flags} when is_map(flags) ->
        state = %__MODULE__{mod: mod, args: init_arg, name: name}

        case init(state, flags) do
          {:ok, state} ->
            :net_kernel.monitor_nodes(true)

            state =
              for node <- Node.list(),
                  alive?(name, node),
                  reduce: state,
                  do: (state -> update_nephews(node, [], state))

            {:ok, state}

          {:error, reason} ->
            {:stop, {:supervisor_data, reason}}
        end

      :ignore ->
        :ignore

      other ->
        {:stop, {:bad_return, {mod, :init, other}}}
    end
  end

  defp init(state, flags) do
    extra_arguments = Map.get(flags, :extra_arguments, [])
    max_children = Map.get(flags, :max_children, :infinity)
    max_restarts = Map.get(flags, :intensity, 1)
    max_seconds = Map.get(flags, :period, 5)
    strategy = Map.get(flags, :strategy, :one_for_one)
    auto_balance = Map.get(flags, :auto_balance, true)
    locator = Map.get(flags, :locator, &__MODULE__.locate/2)

    with :ok <- validate_strategy(strategy),
         :ok <- validate_restarts(max_restarts),
         :ok <- validate_seconds(max_seconds),
         :ok <- validate_dynamic(max_children),
         :ok <- validate_extra_arguments(extra_arguments),
         :ok <- validate_auto_balance(auto_balance),
         :ok <- validate_locator(locator) do
      {:ok,
       %{
         state
         | extra_arguments: extra_arguments,
           max_children: max_children,
           max_restarts: max_restarts,
           max_seconds: max_seconds,
           strategy: strategy,
           auto_balance: auto_balance,
           locator: locator
       }}
    end
  end

  defp validate_strategy(strategy) when strategy in [:one_for_one], do: :ok
  defp validate_strategy(strategy), do: {:error, {:invalid_strategy, strategy}}

  defp validate_restarts(restart) when is_integer(restart) and restart >= 0, do: :ok
  defp validate_restarts(restart), do: {:error, {:invalid_intensity, restart}}

  defp validate_seconds(seconds) when is_integer(seconds) and seconds > 0, do: :ok
  defp validate_seconds(seconds), do: {:error, {:invalid_period, seconds}}

  defp validate_dynamic(:infinity), do: :ok
  defp validate_dynamic(dynamic) when is_integer(dynamic) and dynamic >= 0, do: :ok
  defp validate_dynamic(dynamic), do: {:error, {:invalid_max_children, dynamic}}

  defp validate_extra_arguments(list) when is_list(list), do: :ok
  defp validate_extra_arguments(extra), do: {:error, {:invalid_extra_arguments, extra}}

  defp validate_auto_balance(auto_balance) when is_boolean(auto_balance), do: :ok
  defp validate_auto_balance(auto_balance), do: {:error, {:invalid_auto_balance, auto_balance}}

  defp validate_locator(locator) when is_function(locator, 2), do: :ok
  defp validate_locator(locator), do: {:error, {:invalid_locator, locator}}

  @impl true
  def handle_call({:start_child, child_spec}, from, state = %{name: name, locator: locator}) do
    node = locator.(child_spec, nodes(state))

    if node == node() do
      handle_call({:start_child_local, child_spec}, from, state)
    else
      send({name, node}, {:"$gen_call", from,  {:start_child_local, child_spec}})
      {:noreply, state}
    end
  end

  def handle_call({:start_child_local, child_spec}, from, state) do
    GenServer.cast(self(), {:broadcast_children, state})
    DynamicSupervisor.handle_call({:start_child, child_spec}, from, state)
  end

  def handle_call(request = {:terminate_child, _pid}, from, state) do
    GenServer.cast(self(), {:broadcast_children, state})
    DynamicSupervisor.handle_call(request, from, state)
  end

  defdelegate handle_call(request, from, state), to: DynamicSupervisor

  @impl true
  def handle_cast({:children, node, children}, state) do
    {:noreply, update_nephews(node, children, state)}
  end

  def handle_cast({:broadcast_children, old_state}, state = %{nephews: nephews}) do
    if children(old_state) != children(state) do
      for {node, _} <- nephews,
          do: send_children(node, state)
    end

    {:noreply, state}
  end

  def handle_cast(:rebalance, state = %{name: name, locator: locator}) do
    GenServer.cast(self(), {:broadcast_children, state})
    nodes = nodes(state)

    state =
      for {pid, child_spec} <- children(state),
          node = locator.(child_spec, nodes),
          node != node(),
          reduce: state do
        state ->
          {:reply, _, state} =
            DynamicSupervisor.handle_call({:terminate_child, pid}, {nil, nil}, state)

          send({name, node}, {:"$gen_call", {nil, nil}, {:start_child_local, child_spec}})
          state
      end

    {:noreply, state}
  end

  defdelegate handle_cast(request, state), to: DynamicSupervisor

  @impl true
  def handle_info({:nodeup, node}, state = %{name: name}) do
    if alive?(name, node) do
      {:noreply, update_nephews(node, [], state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:nodedown, _node}, state) do
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, _ref, :process, {name, node}, _reason},
        state = %{name: name, nephews: nephews, locator: locator}
      ) do
    {children, nephews} = Map.pop(nephews, node, [])
    state = %{state | nephews: nephews}
    GenServer.cast(self(), {:broadcast_children, state})
    nodes = nodes(state)

    state =
      for child_spec <- children,
          node = locator.(child_spec, nodes),
          node == node(),
          reduce: state do
        state ->
          {:reply, _, state} =
            DynamicSupervisor.handle_call({:start_child, child_spec}, {nil, nil}, state)

          state
      end

    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    case maybe_restart_child(pid, reason, state) do
      {:ok, state} -> {:noreply, state}
      {:shutdown, state} -> {:stop, :shutdown, state}
    end
  end

  def handle_info({:"$gen_restart", pid}, state) do
    %{children: children} = state

    case children do
      %{^pid => restarting_args} ->
        {:restarting, child} = restarting_args

        case restart_child(pid, child, state) do
          {:ok, state} -> {:noreply, state}
          {:shutdown, state} -> {:stop, :shutdown, state}
        end

      # We may hit clause if we send $gen_restart and then
      # someone calls terminate_child, removing the child.
      %{} ->
        {:noreply, state}
    end
  end

  defdelegate handle_info(msg, state), to: DynamicSupervisor

  defp start_child(m, f, a) do
    try do
      apply(m, f, a)
    catch
      kind, reason ->
        {:error, exit_reason(kind, reason, __STACKTRACE__)}
    else
      {:ok, pid, extra} when is_pid(pid) -> {:ok, pid, extra}
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      :ignore -> :ignore
      {:error, _} = error -> error
      other -> {:error, other}
    end
  end

  defp save_child(pid, mfa, restart, shutdown, type, modules, state) do
    mfa = mfa_for_restart(mfa, restart)
    put_in(state.children[pid], {mfa, restart, shutdown, type, modules})
  end

  defp mfa_for_restart({m, f, _}, :temporary), do: {m, f, :undefined}
  defp mfa_for_restart(mfa, _), do: mfa

  defp exit_reason(:exit, reason, _), do: reason
  defp exit_reason(:error, reason, stack), do: {reason, stack}
  defp exit_reason(:throw, value, stack), do: {{:nocatch, value}, stack}

  defp maybe_restart_child(pid, reason, %{children: children} = state) do
    case children do
      %{^pid => {_, restart, _, _, _} = child} ->
        maybe_restart_child(restart, reason, pid, child, state)

      %{} ->
        {:ok, state}
    end
  end

  defp maybe_restart_child(:permanent, reason, pid, child, state) do
    report_error(:child_terminated, reason, pid, child, state)
    restart_child(pid, child, state)
  end

  defp maybe_restart_child(_, :normal, pid, _child, state) do
    {:ok, delete_child(pid, state)}
  end

  defp maybe_restart_child(_, :shutdown, pid, _child, state) do
    {:ok, delete_child(pid, state)}
  end

  defp maybe_restart_child(_, {:shutdown, _}, pid, _child, state) do
    {:ok, delete_child(pid, state)}
  end

  defp maybe_restart_child(:transient, reason, pid, child, state) do
    report_error(:child_terminated, reason, pid, child, state)
    restart_child(pid, child, state)
  end

  defp maybe_restart_child(:temporary, reason, pid, child, state) do
    report_error(:child_terminated, reason, pid, child, state)
    {:ok, delete_child(pid, state)}
  end

  defp delete_child(pid, %{children: children} = state) do
    GenServer.cast(self(), {:broadcast_children, state})
    %{state | children: Map.delete(children, pid)}
  end

  defp restart_child(pid, child, state) do
    case add_restart(state) do
      {:ok, %{strategy: strategy} = state} ->
        case restart_child(strategy, pid, child, state) do
          {:ok, state} ->
            {:ok, state}

          {:try_again, state} ->
            send(self(), {:"$gen_restart", pid})
            {:ok, state}
        end

      {:shutdown, state} ->
        report_error(:shutdown, :reached_max_restart_intensity, pid, child, state)
        {:shutdown, delete_child(pid, state)}
    end
  end

  defp add_restart(state) do
    %{max_seconds: max_seconds, max_restarts: max_restarts, restarts: restarts} = state

    now = :erlang.monotonic_time(1)
    restarts = add_restart([now | restarts], now, max_seconds)
    state = %{state | restarts: restarts}

    if length(restarts) <= max_restarts do
      {:ok, state}
    else
      {:shutdown, state}
    end
  end

  defp add_restart(restarts, now, period) do
    for then <- restarts, now <= then + period, do: then
  end

  defp restart_child(:one_for_one, current_pid, child, state) do
    {{m, f, args} = mfa, restart, shutdown, type, modules} = child
    %{extra_arguments: extra} = state

    case start_child(m, f, extra ++ args) do
      {:ok, pid, _} ->
        state = delete_child(current_pid, state)
        {:ok, save_child(pid, mfa, restart, shutdown, type, modules, state)}

      {:ok, pid} ->
        state = delete_child(current_pid, state)
        {:ok, save_child(pid, mfa, restart, shutdown, type, modules, state)}

      :ignore ->
        {:ok, delete_child(current_pid, state)}

      {:error, {:already_started, _pid}} ->
        state = %{state | restarts: tl(state.restarts)}
        {:ok, delete_child(current_pid, state)}

      {:error, reason} ->
        report_error(:start_error, reason, {:restarting, current_pid}, child, state)
        state = put_in(state.children[current_pid], {:restarting, child})
        {:try_again, state}
    end
  end

  defp report_error(error, reason, pid, child, %{name: name, extra_arguments: extra}) do
    :error_logger.error_report(
      :supervisor_report,
      supervisor: name,
      errorContext: error,
      reason: reason,
      offender: extract_child(pid, child, extra)
    )
  end

  defp extract_child(pid, {{m, f, args}, restart, shutdown, type, _modules}, extra) do
    [
      pid: pid,
      id: :undefined,
      mfargs: {m, f, extra ++ args},
      restart_type: restart,
      shutdown: shutdown,
      child_type: type
    ]
  end

  defp children(%{children: children}) do
    children
    |> Enum.map(fn
      {pid, {:restarting, child_spec}} -> {pid, child_spec}
      {pid, child_spec} -> {pid, child_spec}
    end)
    |> Enum.filter(fn
      {_, {_, :temporary, _, _, _}} -> false
      _ -> true
    end)
    |> Map.new()
  end

  defp send_children(node, state = %{name: name}) do
    GenServer.cast({name, node}, {:children, node(), Map.values(children(state))})
  end

  defp alive?(name, node) do
    nil != :rpc.call(node, Process, :whereis, [name])
  end

  defp update_nephews(
         node,
         children,
         state = %{name: name, nephews: nephews, auto_balance: auto_balance}
       ) do
    unless Map.has_key?(nephews, node) do
      Process.monitor({name, node})
      send_children(node, state)
      if auto_balance, do: rebalance(self())
    end

    %{state | nephews: Map.put(nephews, node, children)}
  end
end
