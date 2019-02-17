# GlobalSupervisor

A supervisor that dynamically distributes children across the cluster.

A `GlobalSupervisor` is like a `DynamicSupervisor` that coordinates with other
GlobalSupervisors registered with the same name in the cluster to dynamically
distribute children across the cluster.

A `GlobalSupervisor` has the same API and behaviour of a `DynamicSupervisor`
with some minor differences to provide distributed functionality.
When you start a child using `start_child/2`, global supervisor uses a
consistent hash algorithm to decide on which node it should be started.
When a node goes down, all children running on that node will be
redistributed on remaining nodes. When a new node is added to the cluster
global supervisor by default automatically rebalances distribution of
running children.

In case of a network split each partition restarts children running on the
other part assuming that part is down. Once the partition is healed,
children will be rebalanced again, but rebalancing might lead to some children
being started again on the same node which they started on initially.
Also when auto balancing is disabled, a healed netsplit might have multiple
instances of the same child running on two or more nodes. To prevent two
instances of the same child stay running after a net split heals, you need
to register each child process with a unique name. Local names will only
prevent running multiple instances of a child on a single node, you can
use `:global` registry or any other distributed registry to prevent running
multiple instances of a child across the cluster.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `global_supervisor` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:global_supervisor, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/global_supervisor](https://hexdocs.pm/global_supervisor).

