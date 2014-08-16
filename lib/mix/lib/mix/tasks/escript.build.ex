defmodule Mix.Tasks.Escript.Build do
  use Mix.Task
  use Bitwise, only_operators: true

  @shortdoc "Builds an escript for the project"
  @recursive true

  @moduledoc ~S"""
  Builds an escript for the project.

  An escript is an executable that can be invoked from the
  command line.  An escript can run on any machine that has
  Erlang installed and by default does not require Elixir to
  be installed, as Elixir is embedded as part of the escript.

  This task guarantees the project and its dependencies are
  compiled and packages them inside an escript.

  ## Command line options

    * `--force`      - forces compilation regardless of modification times
    * `--no-compile` - skips compilation to .beam files

  ## Configuration

  The following option must be specified in your `mix.exs` under `:escript`
  key:

    * `:main_module` - the module to be invoked once the escript starts.
      The module must contain a function named `main/1` that will receive the
      command line arguments as binaries.

  The remaining options can be specified to further customize the escript:

    * `:name` - the name of the generated escript.
      Defaults to app name.

    * `:path` - the path to write the escript to.
      Defaults to app name.

    * `:app` - the app to start with the escript.
      Defaults to app name. Set it to `nil` if no application should
      be started.

    * `:embed_elixir` - if `true` embed elixir and its children apps
      (`ex_unit`, `mix`, etc.) mentioned in the `:applications` list inside the
      `application` function in `mix.exs`.
      Defaults to `true` for Elixir projects.

    * `:shebang` - shebang interpreter directive used to execute the escript.
      Defaults to `"#! /usr/bin/env escript\n"`.

    * `:comment` - comment line to follow shebang directive in the escript.
      Defaults to `""`.

    * `:emu_args` - emulator arguments to embed in the escript file.
      Defaults to `""`.

  ## Example

      defmodule MyApp.Mixfile do
        def project do
          [app: :myapp,
           version: "0.0.1",
           escript: escript]
        end

        def escript do
          [main_module: MyApp.CLI]
        end
      end

  """
  def run(args) do
    Mix.Project.get!
    {opts, _, _} = OptionParser.parse(args, switches: [force: :boolean, compile: :boolean])

    if Keyword.get(opts, :compile, true) do
      Mix.Task.run :compile, args
    end

    escriptize(Mix.Project.config, opts[:force])
  end

  defp escriptize(project, force) do
    escript_opts = project[:escript] || []

    script_name  = to_string(escript_opts[:name] || project[:app])
    filename     = escript_opts[:path] || script_name
    main         = escript_opts[:main_module]
    app          = Keyword.get(escript_opts, :app, project[:app])
    files        = project_files()
    language     = Keyword.get(project, :language, :elixir)

    escript_mod = String.to_atom(Atom.to_string(app) <> "_escript")

    cond do
      !script_name ->
        Mix.raise "Could not generate escript, no name given, " <>
          "set :name escript option or :app in the project settings"

      !main or !Code.ensure_loaded?(main)->
        Mix.raise "Could not generate escript, please set :main_module " <>
          "in your project configuration (under `:escript` option) to a module that implements main/1"

      force || Mix.Utils.stale?(files, [filename]) ->
        tuples = gen_main(escript_mod, main, app, language) ++
                 to_tuples(files) ++ deps_tuples() ++
                 embed_tuples(escript_opts, language)

        case :zip.create 'mem', tuples, [:memory] do
          {:ok, {'mem', zip}} ->
            shebang  = escript_opts[:shebang] || "#! /usr/bin/env escript\n"
            comment  = build_comment(escript_opts[:comment])
            emu_args = build_emu_args(escript_opts[:emu_args], escript_mod)

            script = IO.iodata_to_binary([shebang, comment, emu_args, zip])
            File.mkdir_p!(Path.dirname(filename))
            File.write!(filename, script)
            set_perms(filename)
          {:error, error} ->
            Mix.raise "Error creating escript: #{error}"
        end

        Mix.shell.info "Generated escript #{filename} with MIX_ENV=#{Mix.env}"
        :ok
      true ->
        :noop
    end
  end

  defp project_files do
    get_files(Mix.Project.app_path)
  end

  defp get_files(app) do
    Path.wildcard("#{app}/ebin/*.{app,beam}") ++
      (Path.wildcard("#{app}/priv/**/*") |> Enum.filter(&File.regular?/1))
  end

  defp get_tuples(app) do
    get_files(app) |> to_tuples
  end

  defp to_tuples(files) do
    for f <- files do
      {String.to_char_list(Path.basename(f)), File.read!(f)}
    end
  end

  defp set_perms(filename) do
    stat = File.stat!(filename)
    :ok  = File.chmod(filename, stat.mode ||| 0o111)
  end

  defp deps_tuples do
    deps = Mix.Dep.loaded(env: Mix.env) || []
    Enum.flat_map(deps, fn dep -> get_tuples(dep.opts[:build]) end)
  end

  defp embed_tuples(escript_opts, language) do
    if Keyword.get(escript_opts, :embed_elixir, language == :elixir) do
      Enum.flat_map [:elixir|extra_apps()], &app_tuples(&1)
    else
      []
    end
  end

  defp extra_apps() do
    mod = Mix.Project.get!

    extra_apps =
      if function_exported?(mod, :application, 0) do
        mod.application[:applications]
      end

    Enum.filter(extra_apps || [], &(&1 in [:eex, :ex_unit, :mix, :iex, :logger]))
  end

  defp app_tuples(app) do
    case :code.where_is_file('#{app}.app') do
      :non_existing -> Mix.raise "Could not find application #{app}"
      file -> get_tuples(Path.dirname(Path.dirname(file)))
    end
  end

  defp build_comment(user_comment) do
    "%% #{user_comment}\n"
  end

  defp build_emu_args(user_args, escript_mod) do
    "%%! -escript main #{escript_mod} #{user_args}\n"
  end

  defp gen_main(name, module, app, language) do
    config =
      if File.regular?("config/config.exs") do
        Mix.Config.read!("config/config.exs")
      else
        []
      end

    module_body = quote do
      @module unquote(module)
      @config unquote(config)
      @app unquote(app)

      # We need to use Erlang modules at this point
      # because we are not sure Elixir is available.
      unquote(module_body_for(language))
    end

    {:module, ^name, binary, _} = Module.create(name, module_body, Macro.Env.location(__ENV__))
    [{'#{name}.beam', binary}]
  end

  defp module_body_for(:elixir) do
    quote do
      def main(args) do
        case :application.ensure_all_started(:elixir) do
          {:ok, _} ->
            load_config(@config)
            start_app(@app)
            args = Enum.map(args, &List.to_string(&1))
            Kernel.CLI.run fn _ -> @module.main(args) end, true
          _ ->
            :io.put_chars :standard_error, "Elixir is not available, aborting.\n"
            :erlang.halt(1)
        end
      end

      defp load_config(config) do
        for {app, kw} <- config, {k, v} <- kw do
          :application.set_env(app, k, v, persistent: true)
        end
        :ok
      end

      defp start_app(nil) do
        :ok
      end

      defp start_app(app) do
        case :application.ensure_all_started(app) do
          {:ok, _} -> :ok
          {:error, {app, reason}} ->
            io_error "Could not start application #{app}: " <>
              Application.format_error(reason)
            System.halt(1)
        end
      end

      defp io_error(message) do
        IO.puts :stderr, IO.ANSI.format([:red, :bright, message])
      end
    end
  end

  defp module_body_for(:erlang) do
    quote do
      def main(args) do
        load_config(@config)
        start_app(@app)
        @module.main(args)
      end

      defp load_config(config) do
        :lists.foreach(fn {app, kw} ->
          :lists.foreach(fn {k, v} ->
            :application.set_env(app, k, v, persistent: true)
          end, kw)
        end, config)
        :ok
      end

      defp start_app(nil) do
        :ok
      end

      defp start_app(app) do
        case :application.ensure_all_started(app) do
          {:ok, _} -> :ok
          {:error, {app, reason}} ->
            io_error ["Could not start application #{app}: ",
                                              :io_lib.format('~p~n', [reason])]
            :erlang.halt(1)
        end
      end

      defp io_error(message) do
        :io.put_chars(:standard_error, message)
      end
    end
  end
end
