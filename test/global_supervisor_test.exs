defmodule GlobalSupervisorTest do
  use ExUnit.Case
  doctest GlobalSupervisor

  test "greets the world" do
    assert GlobalSupervisor.hello() == :world
  end
end
