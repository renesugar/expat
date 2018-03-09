defmodule Expat.Macro do
  @moduledoc """
             Expat internals for working with Macro.t()
             """ && false

  alias Expat, as: E

  @doc "Defines a named pattern"
  @spec define_pattern(defm :: :defmacro | :defmacrop, E.pattern()) :: E.pattern()
  def define_pattern(defm, pattern) do
    name = pattern_name(pattern)
    escaped = pattern |> mark_non_guarded |> mark_bindable |> Macro.escape()

    quote do
      unquote(defm)(unquote(name)(opts \\ []) when is_list(opts)) do
        Expat.Macro.expand(unquote(escaped), opts)
      end
    end
  end

  @doc "Expands a pattern"
  @spec expand(pattern :: E.pattern(), opts :: list) :: Macro.t()
  def expand(pattern, opts) do
    binds = Keyword.delete(opts, :_)
    opts = Keyword.get(opts, :_, [])
    guard = pattern_guard(pattern)

    value =
      pattern
      |> pattern_value
      |> bind(binds)
      |> make_under

    result = (guard && {:when, [context: Elixir], [value, guard]}) || value
    (opts[:escape] && Macro.escape(result)) || result
  end

  def expand_inside(expr, opts) do
    Macro.postwalk(expr, &do_expand_inside(&1, opts))
  end

  ## Private parts bellow

  defp do_expand_inside({defn, c, [head, rest]}, opts)
       when defn == :def or defn == :defp or defn == :defmacro or defn == :defmacrop do
    args = pattern_args(head)
    guard = pattern_guard(head)

    {args, guard} = expand_args_collecting_guard(args, guard, opts)
    head =
      head
      |> update_pattern_guard(fn _ -> guard end)
      |> update_pattern_args(fn _ -> args end)

    {defn, c, [head, rest]}
  end

  defp do_expand_inside({:fn, c, clauses}, opts) do
    clauses =
      clauses
      |> Enum.map(fn {:->, a, [[e], body]} ->
        {:->, a, [[expand_calls_inside(e, opts)], body]}
      end)

    {:fn, c, clauses}
  end

  defp do_expand_inside({:case, c, [v, [do: clauses]]}, opts) do
    clauses =
      clauses
      |> Enum.map(fn {:->, a, [[e], body]} ->
        {:->, a, [[expand_calls_inside(e, opts)], body]}
      end)

    {:case, c, [v, [do: clauses]]}
  end

  defp do_expand_inside({:with, c, clauses}, opts) do
    clauses =
      clauses
      |> Enum.map(fn
        {:<-, a, [p, e]} ->
          {:<-, a, [expand_calls_inside(p, opts), e]}
        x -> x
       end)
    {:with, c, clauses}
  end

  defp do_expand_inside(ast, _opts), do: ast

  defp expand_args_collecting_guard(args, guard, opts) do
    Enum.map_reduce(args, guard, fn
      arg, guard -> expand_arg_collecting_guard(arg, guard, opts)
    end)
  end

  defp expand_arg_collecting_guard(ast, guard, opts) do
    expand_collect(ast, guard, &collect_guard/2, opts)
  end

  defp expand_collect(ast, initial, collect, opts) do
    env = Keyword.get(opts, :_, []) |> Keyword.get(:env, __ENV__)
    ast
    |> Macro.traverse(
      initial,
      fn
        {c, m, [u]}, guard when is_list(u) ->
          {c, m, [opts ++ u]}
          |> Code.eval_quoted([], env)
          |> elem(0)
          |> collect.(guard)

        {c, m, []}, guard ->
          {c, m, [opts]}
          |> Code.eval_quoted([], env)
          |> elem(0)
          |> collect.(guard)

        x, y ->
          {x, y}
      end,
      fn x, y -> {x, y} end)
  end

  defp collect_guard({:when, _, [expr, guard]}, prev) do
    {expr, and_guard(prev, guard)}
  end

  defp collect_guard(expr, guard) do
    {expr, guard}
  end

  defp and_guard(nil, guard), do: guard
  defp and_guard(a, b), do: quote(do: unquote(a) and unquote(b))

  defp expand_calls_inside(ast, opts) do
    ast
    |> expand_collect(nil, fn x, y -> {x, y} end, opts)
    |> elem(0)
  end

  @doc "Make underable variables an underscore to be ignored" && false
  defp make_under(pattern) do
    Macro.prewalk(pattern, fn
      v = {_, m, _} ->
        m[:underable] && {:_, [], nil} || v

      x ->
        x
    end)
  end

  @doc "Mark variables in pattern that are not used in guards" && false
  defp mark_non_guarded(pattern) do
    vars_in_guards = pattern |> pattern_guard |> ast_variables

    value =
      pattern |> pattern_value
      |> Macro.prewalk(fn
        v = {_, [{:underable, true} | _], _} ->
          v

        v = {n, m, c} when is_atom(n) and is_atom(c) ->
          unless Enum.member?(vars_in_guards, v) do
            {n, [underable: true] ++ m, c}
          else
            v
          end

        x ->
          x
      end)

    pattern |> update_pattern_value(fn _ -> value end)
  end

  @doc "Marks all variables with the name they can be bound to" && false
  defp mark_bindable(pattern) do
    name = pattern_name(pattern)

    pattern
    |> Macro.prewalk(fn
      {a, m, c} when is_atom(a) and is_atom(c) ->
        {:"#{name} #{a}", [bindable: a] ++ m, c}

      x ->
        x
    end)
  end

  defp ast_variables(nil), do: []

  defp ast_variables(ast) do
    {_, acc} =
      Macro.traverse(ast, [], fn x, y -> {x, y} end, fn
        v = {n, _, c}, acc when is_atom(n) and is_atom(c) -> {v, [v] ++ acc}
        ast, acc -> {ast, acc}
      end)

    acc
  end

  defp bind(pattern, binds) do
    pattern
    |> Macro.prewalk(fn
      x = {_, [{:bound, _} | _], _} ->
        x

      {a, m = [{:bindable, b} | _], c} ->
        case binds[b] do
          nil ->
            {a, m, c}
          expr ->
            m[:underable] && expr || {:=, [bound: true], [expr, {a, [bound: true] ++ m, c}]}
        end

      x ->
        x
    end)
  end

  defp update_pattern_value(pattern, up) when is_function(up, 1) do
    update_pattern_head(pattern, fn {name, c, [value]} ->
      {name, c, [up.(value)]}
    end)
  end

  defp pattern_value(pattern) do
    {_, _, [value]} = pattern |> pattern_head
    value
  end

  defp pattern_args(pattern) do
    {_, _, args} = pattern |> pattern_head
    args
  end

  defp update_pattern_args(pattern, up) when is_function(up, 1) do
    update_pattern_head(pattern, fn {name, c, args} ->
      {name, c, up.(args)}
    end)
  end

  defp update_pattern_guard(pattern, up) when is_function(up, 1) do
    case pattern do
      {:when, x, [head, guard]} ->
        new_guard = up.(guard)

        if new_guard do
          {:when, x, [head, new_guard]}
        else
          head
        end

      head ->
        new_guard = up.(nil)

        if new_guard do
          {:when, [context: Elixir], [head, new_guard]}
        else
          head
        end
    end
  end

  defp pattern_guard(pattern) do
    case pattern do
      {:when, _, [_head, guard]} -> guard
      _ -> nil
    end
  end

  defp update_pattern_head(pattern, up) when is_function(up, 1) do
    case pattern do
      {:when, x, [head, guard]} ->
        {:when, x, [up.(head), guard]}

      head ->
        up.(head)
    end
  end

  defp pattern_head(pattern) do
    case pattern do
      {:when, _, [head, _guard]} -> head
      head -> head
    end
  end

  defp pattern_name(pattern) do
    {name, _, _} = pattern |> pattern_head
    name
  end
end
