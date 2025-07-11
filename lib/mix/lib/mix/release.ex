# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

defmodule Mix.Release do
  @moduledoc """
  Defines the release structure and convenience for assembling releases.
  """

  @doc """
  The Mix.Release struct has the following read-only fields:

    * `:name` - the name of the release as an atom
    * `:version` - the version of the release as a string
    * `:path` - the path to the release root
    * `:version_path` - the path to the release version inside the release
    * `:applications` - a map of application with their definitions
    * `:erts_source` - the ERTS source as a charlist (or nil)
    * `:erts_version` - the ERTS version as a charlist

  The following fields may be modified as long as they keep their defined types:

    * `:boot_scripts` - a map of boot scripts with the boot script name
      as key and a keyword list with **all** applications that are part of
      it and their modes as value
    * `:config_providers` - a list of `{config_provider, term}` tuples where the
      first element is a module that implements the `Config.Provider` behaviour
      and `term` is the value given to it on `c:Config.Provider.init/1`
    * `:options` - a keyword list with all other user supplied release options
    * `:overlays` - a list of extra files added to the release. If you have a custom
      step adding extra files to a release, you can add these files to the `:overlays`
      field so they are also considered on further commands, such as tar/zip. Each entry
      in overlays is the relative path to the release root of each file
    * `:steps` - a list of functions that receive the release and returns a release.
      Must also contain the atom `:assemble` which is the internal assembling step.
      May also contain the atom `:tar` to create a tarball of the release.

  """
  defstruct [
    :name,
    :version,
    :path,
    :version_path,
    :applications,
    :boot_scripts,
    :erts_source,
    :erts_version,
    :config_providers,
    :options,
    :overlays,
    :steps
  ]

  @type mode :: :permanent | :transient | :temporary | :load | :none
  @type application :: atom()
  @type t :: %__MODULE__{
          name: atom(),
          version: String.t(),
          path: String.t(),
          version_path: String.t(),
          applications: %{application() => keyword()},
          boot_scripts: %{atom() => [{application(), mode()}]},
          erts_version: charlist(),
          erts_source: charlist() | nil,
          config_providers: [{module, term}],
          options: keyword(),
          overlays: list(String.t()),
          steps: [(t -> t) | :assemble, ...]
        }

  @typedoc """
  Options for stripping BEAM files.
  """
  @type strip_beam_opts :: [
          keep: [String.t()],
          compress: boolean()
        ]

  @typedoc """
  Erlang/OTP sys.config structure.

  A list of tuples where each tuple contains an application name and its
  configuration as a keyword list. This is the standard format for Erlang
  application configuration.
  """
  @type sys_config :: [{application(), keyword()}]

  @default_apps [kernel: :permanent, stdlib: :permanent, elixir: :permanent, sasl: :permanent]
  @safe_modes [:permanent, :temporary, :transient]
  @unsafe_modes [:load, :none]
  @additional_chunks ~w(Attr)c
  @copy_app_dirs ["priv", "include"]

  @doc false
  @spec from_config!(atom, keyword, keyword) :: t
  def from_config!(name, config, overrides) do
    {name, apps, opts} = find_release(name, config)

    if not (Atom.to_string(name) =~ ~r/^[a-z][a-z0-9_]*$/) do
      Mix.raise(
        "Invalid release name. A release name must start with a lowercase ASCII letter, " <>
          "followed by lowercase ASCII letters, numbers, or underscores, got: #{inspect(name)}"
      )
    end

    opts =
      [overwrite: false, quiet: false, strip_beams: true]
      |> Keyword.merge(opts)
      |> Keyword.merge(overrides)

    {include_erts, opts} = Keyword.pop(opts, :include_erts, true)
    {erts_source, erts_lib_dir, erts_version} = erts_data(include_erts)

    deps_apps = Mix.Project.deps_apps()
    loaded_apps = load_apps(apps, deps_apps, %{}, erts_lib_dir, [], apps)

    # Make sure IEx is either an active part of the release or add it as none.
    {loaded_apps, apps} =
      if Map.has_key?(loaded_apps, :iex) do
        {loaded_apps, apps}
      else
        {load_apps([iex: :none], deps_apps, loaded_apps, erts_lib_dir, [], apps),
         apps ++ [iex: :none]}
      end

    start_boot = build_start_boot(loaded_apps, apps)
    start_clean_boot = build_start_clean_boot(start_boot)

    {path, opts} =
      Keyword.pop_lazy(opts, :path, fn ->
        Path.join([Mix.Project.build_path(config), "rel", Atom.to_string(name)])
      end)

    path = Path.absname(path)

    {version, opts} =
      Keyword.pop_lazy(opts, :version, fn ->
        config[:version] ||
          Mix.raise(
            "No :version found. Please make sure a :version is set in your project definition " <>
              "or inside the release the configuration"
          )
      end)

    version =
      case version do
        {:from_app, app} ->
          Application.load(app)
          version = Application.spec(app, :vsn)

          if !version do
            Mix.raise(
              "Could not find version for #{inspect(app)}, please make sure the application exists"
            )
          end

          to_string(version)

        "" ->
          Mix.raise("The release :version cannot be an empty string")

        _ ->
          version
      end

    {config_providers, opts} = Keyword.pop(opts, :config_providers, [])
    {steps, opts} = Keyword.pop(opts, :steps, [:assemble])
    validate_steps!(steps)

    %Mix.Release{
      name: name,
      version: version,
      path: path,
      version_path: Path.join([path, "releases", version]),
      erts_source: erts_source,
      erts_version: erts_version,
      applications: Map.delete(loaded_apps, :erts),
      boot_scripts: %{start: start_boot, start_clean: start_clean_boot},
      config_providers: config_providers,
      options: opts,
      overlays: [],
      steps: steps
    }
  end

  defp find_release(name, config) do
    {name, opts_fun_or_list} = lookup_release(name, config) || infer_release(config)
    opts = if is_function(opts_fun_or_list, 0), do: opts_fun_or_list.(), else: opts_fun_or_list
    {apps, opts} = Keyword.pop(opts, :applications, [])

    if apps == [] and Mix.Project.umbrella?(config) do
      bad_umbrella!()
    end

    app = Keyword.get(config, :app)
    apps = Keyword.merge(@default_apps, apps)

    if is_nil(app) or Keyword.has_key?(apps, app) do
      {name, apps, opts}
    else
      {name, apps ++ [{app, :permanent}], opts}
    end
  end

  defp lookup_release(nil, config) do
    case Keyword.get(config, :releases, []) do
      [] ->
        nil

      [{name, opts}] ->
        {name, opts}

      [_ | _] ->
        case Keyword.get(config, :default_release) do
          nil ->
            Mix.raise(
              "\"mix release\" was invoked without a name but there are multiple releases. " <>
                "Please call \"mix release NAME\" or set :default_release in your project configuration"
            )

          name ->
            lookup_release(name, config)
        end
    end
  end

  defp lookup_release(name, config) do
    if opts = config[:releases][name] do
      {name, opts}
    else
      found = Keyword.get(config, :releases, [])

      Mix.raise(
        "Unknown release #{inspect(name)}. " <>
          "The available releases are: #{inspect(Keyword.keys(found))}"
      )
    end
  end

  defp infer_release(config) do
    if Mix.Project.umbrella?(config) do
      bad_umbrella!()
    else
      {Keyword.fetch!(config, :app), []}
    end
  end

  defp bad_umbrella! do
    Mix.raise("""
    Umbrella projects require releases to be explicitly defined with \
    a non-empty applications key that chooses which umbrella children \
    should be part of the releases:

        releases: [
          foo: [
            applications: [child_app_foo: :permanent]
          ],
          bar: [
            applications: [child_app_bar: :permanent]
          ]
        ]

    Alternatively you can perform the release from the children applications
    """)
  end

  defp erts_data(erts_data) when is_function(erts_data) do
    erts_data(erts_data.())
  end

  defp erts_data(false) do
    {nil, :code.lib_dir(), :erlang.system_info(:version)}
  end

  defp erts_data(true) do
    version = :erlang.system_info(:version)
    {:filename.join(:code.root_dir(), ~c"erts-#{version}"), :code.lib_dir(), version}
  end

  defp erts_data(erts_source) when is_binary(erts_source) do
    if File.exists?(erts_source) do
      [_, erts_version] = erts_source |> Path.basename() |> String.split("-")
      erts_lib_dir = erts_source |> Path.dirname() |> Path.join("lib") |> to_charlist()
      {to_charlist(erts_source), erts_lib_dir, to_charlist(erts_version)}
    else
      Mix.raise("Could not find ERTS system at #{inspect(erts_source)}")
    end
  end

  defp load_apps(apps, deps_apps, seen, otp_root, optional, overrides) do
    for {app, mode} <- apps, reduce: seen do
      seen ->
        properties = seen[app]

        cond do
          is_nil(properties) ->
            load_app(app, overrides[app] || mode, deps_apps, seen, otp_root, optional, overrides)

          Keyword.has_key?(overrides, app) ->
            seen

          new_mode = merge_mode!(app, mode, properties[:mode]) ->
            apps =
              properties
              |> Keyword.get(:applications, [])
              |> Enum.map(&{&1, new_mode})

            seen = put_in(seen[app][:mode], new_mode)
            optional = Keyword.get(properties, :optional_applications, [])
            load_apps(apps, deps_apps, seen, otp_root, optional, overrides)

          true ->
            seen
        end
    end
  end

  defp merge_mode!(_app, mode, mode), do: nil

  defp merge_mode!(app, left, right) do
    if left == :included or right == :included do
      Mix.raise(
        "#{inspect(app)} is listed both as a regular application and as an included application"
      )
    else
      merge_mode(left, right)
    end
  end

  defp merge_mode(:none, other), do: other
  defp merge_mode(other, :none), do: other
  defp merge_mode(:load, other), do: other
  defp merge_mode(other, :load), do: other
  defp merge_mode(:temporary, other), do: other
  defp merge_mode(other, :temporary), do: other
  defp merge_mode(:transient, other), do: other
  defp merge_mode(other, :transient), do: other
  defp merge_mode(:permanent, other), do: other
  defp merge_mode(other, :permanent), do: other

  defp load_app(app, mode, deps_apps, seen, otp_root, optional, overrides) do
    cond do
      path = app not in deps_apps && otp_path(otp_root, app) ->
        do_load_app(app, mode, path, deps_apps, seen, otp_root, true, overrides)

      path = code_path(app) ->
        do_load_app(app, mode, path, deps_apps, seen, otp_root, false, overrides)

      app in optional ->
        seen

      true ->
        Mix.raise("Could not find application #{inspect(app)}")
    end
  end

  defp otp_path(otp_root, app) do
    path = Path.join(otp_root, "#{app}-*")

    case Path.wildcard(path) do
      [] -> nil
      paths -> paths |> Enum.sort() |> List.last() |> to_charlist()
    end
  end

  defp code_path(app) do
    case :code.lib_dir(app) do
      {:error, :bad_name} -> nil
      path -> path
    end
  end

  defp do_load_app(app, mode, path, deps_apps, seen, otp_root, otp_app?, overrides) do
    case :file.consult(Path.join(path, "ebin/#{app}.app")) do
      {:ok, terms} ->
        [{:application, ^app, properties}] = terms
        value = [path: path, otp_app?: otp_app?, mode: mode] ++ properties
        seen = Map.put(seen, app, value)
        child_mode = if mode == :included, do: :load, else: mode

        applications =
          properties
          |> Keyword.get(:applications, [])
          |> Enum.map(&{&1, child_mode})

        optional = Keyword.get(properties, :optional_applications, [])
        seen = load_apps(applications, deps_apps, seen, otp_root, optional, overrides)

        included_applications =
          properties
          |> Keyword.get(:included_applications, [])
          |> Enum.map(&{&1, :included})

        load_apps(included_applications, deps_apps, seen, otp_root, [], overrides)

      {:error, reason} ->
        Mix.raise("Could not load #{app}.app. Reason: #{inspect(reason)}")
    end
  end

  defp build_start_boot(all_apps, specified_apps) do
    specified_apps ++
      Enum.sort(
        for(
          {app, props} <- all_apps,
          not List.keymember?(specified_apps, app, 0),
          do: {app, boot_mode(props[:mode])}
        )
      )
  end

  defp boot_mode(:included), do: :load
  defp boot_mode(mode), do: mode

  defp build_start_clean_boot(boot) do
    for({app, mode} <- boot, do: {app, if(mode == :none, do: :none, else: :load)})
    |> Keyword.put(:stdlib, :permanent)
    |> Keyword.put(:kernel, :permanent)
  end

  defp validate_steps!(steps) do
    valid_atoms = [:assemble, :tar]

    if not is_list(steps) or Enum.any?(steps, &(&1 not in valid_atoms and not is_function(&1, 1))) do
      Mix.raise("""
      The :steps option must be a list of:

        * anonymous function that receives one argument
        * the atom :assemble or :tar

      Got: #{inspect(steps)}
      """)
    end

    if Enum.count(steps, &(&1 == :assemble)) != 1 do
      Mix.raise("The :steps option must contain the atom :assemble once, got: #{inspect(steps)}")
    end

    if :assemble in Enum.drop_while(steps, &(&1 != :tar)) do
      Mix.raise("The :tar step must come after :assemble")
    end

    if Enum.count(steps, &(&1 == :tar)) > 1 do
      Mix.raise("The :steps option can only contain the atom :tar once")
    end

    :ok
  end

  @doc """
  Makes the `sys.config` structure.

  If there are config providers, then a value is injected into
  the `:elixir` application configuration in `sys_config` to be
  read during boot and trigger the providers.

  It uses the following release options to customize its behavior:

    * `:reboot_system_after_config`
    * `:start_distribution_during_config`
    * `:prune_runtime_sys_config_after_boot`

  In case there are no config providers, it doesn't change `sys_config`.
  """
  @spec make_sys_config(t, sys_config(), Config.Provider.config_path()) ::
          :ok | {:error, String.t()}
  def make_sys_config(release, sys_config, config_provider_path) do
    {sys_config, runtime_config?} =
      merge_provider_config(release, sys_config, config_provider_path)

    path = Path.join(release.version_path, "sys.config")

    args = [runtime_config?, sys_config]
    format = "%% coding: utf-8~n%% RUNTIME_CONFIG=~s~n~tw.~n"
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, IO.chardata_to_string(:io_lib.format(format, args)))

    case :file.consult(path) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        invalid =
          for {app, kv} <- sys_config,
              {key, value} <- kv,
              not valid_config?(value),
              do: """

              Application: #{inspect(app)}
              Key: #{inspect(key)}
              Value: #{inspect(value)}
              """

        message =
          case invalid do
            [] ->
              "Could not read configuration file. Reason: #{inspect(reason)}"

            _ ->
              "Could not read configuration file. It has invalid configuration terms " <>
                "such as functions, references, and pids. Please make sure your configuration " <>
                "is made of numbers, atoms, strings, maps, tuples and lists. The following entries " <>
                "are wrong:\n#{Enum.join(invalid)}"
          end

        {:error, message}
    end
  end

  defp valid_config?(m) when is_map(m),
    do: Enum.all?(Map.delete(m, :__struct__), &valid_config?/1)

  defp valid_config?(l) when is_list(l), do: Enum.all?(l, &valid_config?/1)
  defp valid_config?(t) when is_tuple(t), do: Enum.all?(Tuple.to_list(t), &valid_config?/1)
  defp valid_config?(o), do: is_number(o) or is_atom(o) or is_binary(o)

  defp merge_provider_config(%{config_providers: []}, sys_config, _), do: {sys_config, false}

  defp merge_provider_config(release, sys_config, config_path) do
    {reboot?, extra_config, initial_config} = start_distribution(release)

    prune_runtime_sys_config_after_boot =
      Keyword.get(release.options, :prune_runtime_sys_config_after_boot, false)

    opts = [
      extra_config: initial_config,
      prune_runtime_sys_config_after_boot: prune_runtime_sys_config_after_boot,
      reboot_system_after_config: reboot?,
      validate_compile_env: validate_compile_env(release)
    ]

    init_config = Config.Provider.init(release.config_providers, config_path, opts)
    {Config.Reader.merge(sys_config, init_config ++ extra_config), reboot?}
  end

  defp validate_compile_env(release) do
    with true <- Keyword.get(release.options, :validate_compile_env, true),
         [_ | _] = compile_env <- compile_env(release) do
      compile_env
    else
      _ -> false
    end
  end

  defp compile_env(release) do
    for {_, properties} <- release.applications,
        triplet <- Keyword.get(properties, :compile_env, []),
        do: triplet
  end

  defp start_distribution(%{options: opts}) do
    reboot? = Keyword.get(opts, :reboot_system_after_config, false)
    early_distribution? = Keyword.get(opts, :start_distribution_during_config, false)

    if not reboot? or early_distribution? do
      {reboot?, [], []}
    else
      {true, [kernel: [start_distribution: false]], [kernel: [start_distribution: true]]}
    end
  end

  @doc """
  Copies the cookie to the given path.

  If a cookie option was given, we compare it with
  the contents of the file (if any), and ask the user
  if they want to override.

  If there is no option, we generate a random one
  the first time.
  """
  @spec make_cookie(t, Path.t()) :: :ok
  def make_cookie(release, path) do
    cond do
      cookie = release.options[:cookie] ->
        force? = Keyword.get(release.options, :overwrite, false)
        Mix.Generator.create_file(path, cookie, quiet: true, force: force?)
        :ok

      File.exists?(path) ->
        :ok

      true ->
        File.write!(path, random_cookie())
        :ok
    end
  end

  defp random_cookie, do: Base.encode32(:crypto.strong_rand_bytes(32))

  @doc """
  Makes the start_erl.data file with the
  ERTS version and release versions.
  """
  @spec make_start_erl(t, Path.t()) :: :ok
  def make_start_erl(release, path) do
    File.write!(path, "#{release.erts_version} #{release.version}")
    :ok
  end

  @doc """
  Makes boot scripts.

  It receives a path to the boot file, without extension, such as
  `releases/0.1.0/start` and this command will write `start.rel`,
  `start.boot`, and `start.script` to the given path, returning
  `{:ok, rel_path}` or `{:error, message}`.

  The boot script uses the RELEASE_LIB environment variable, which must
  be accordingly set with `--boot-var` and point to the release lib dir.
  """
  @spec make_boot_script(t, Path.t(), [{application(), mode()}], [String.t()]) ::
          :ok | {:error, String.t()}
  def make_boot_script(release, path, modes, prepend_paths \\ []) do
    with {:ok, rel_spec} <- build_release_spec(release, modes) do
      File.write!(path <> ".rel", consultable(rel_spec))

      sys_path = String.to_charlist(path)

      sys_options = [
        :silent,
        :no_dot_erlang,
        :no_warn_sasl,
        variables: build_variables(release),
        path: build_paths(release)
      ]

      case :systools.make_script(sys_path, sys_options) do
        {:ok, _module, _warnings} ->
          script_path = sys_path ++ ~c".script"
          {:ok, [{:script, rel_info, instructions}]} = :file.consult(script_path)

          instructions =
            instructions
            |> post_stdlib_applies(release)
            |> prepend_paths_to_script(prepend_paths)

          script = {:script, rel_info, instructions}
          File.write!(script_path, consultable(script))
          :ok = :systools.script2boot(sys_path)

        {:error, module, info} ->
          message = module.format_error(info) |> to_string() |> String.trim()
          {:error, message}
      end
    end
  end

  defp build_variables(release) do
    for {_, properties} <- release.applications,
        not Keyword.fetch!(properties, :otp_app?),
        uniq: true,
        do: {~c"RELEASE_LIB", properties |> Keyword.fetch!(:path) |> :filename.dirname()}
  end

  defp build_paths(release) do
    for {_, properties} <- release.applications,
        Keyword.fetch!(properties, :otp_app?),
        do: properties |> Keyword.fetch!(:path) |> Path.join("ebin") |> to_charlist()
  end

  defp build_release_spec(release, modes) do
    %{
      name: name,
      version: version,
      erts_version: erts_version,
      applications: apps,
      options: options
    } = release

    skip_mode_validation_for =
      options
      |> Keyword.get(:skip_mode_validation_for, [])
      |> MapSet.new()

    rel_apps =
      for {app, mode} <- modes do
        properties = Map.get(apps, app) || throw({:error, "Unknown application #{inspect(app)}"})
        children = Keyword.get(properties, :applications, [])
        optional = Keyword.get(properties, :optional_applications, [])
        app in skip_mode_validation_for || validate_mode!(app, mode, modes, children, optional)
        build_app_for_release(app, mode, properties)
      end

    {:ok, {:release, {to_charlist(name), to_charlist(version)}, {:erts, erts_version}, rel_apps}}
  catch
    {:error, message} -> {:error, message}
  end

  defp validate_mode!(app, mode, modes, children, optional) do
    safe_mode? = mode in @safe_modes

    if not safe_mode? and mode not in @unsafe_modes do
      throw(
        {:error,
         "Unknown mode #{inspect(mode)} for #{inspect(app)}. " <>
           "Valid modes are: #{inspect(@safe_modes ++ @unsafe_modes)}"}
      )
    end

    for child <- children do
      child_mode = Keyword.get(modes, child)

      cond do
        is_nil(child_mode) and child not in optional ->
          throw(
            {:error,
             "Application #{inspect(app)} is listed in the release boot, " <>
               "but it depends on #{inspect(child)}, which isn't"}
          )

        safe_mode? and child_mode in @unsafe_modes ->
          throw(
            {:error,
             """
             Application #{inspect(app)} has mode #{inspect(mode)} but it depends on \
             #{inspect(child)} which is set to #{inspect(child_mode)}. If you really want \
             to set such mode for #{inspect(child)} make sure that all applications that depend \
             on it are also set to :load or :none, otherwise your release will fail to boot
             """}
          )

        true ->
          :ok
      end
    end
  end

  defp build_app_for_release(app, mode, properties) do
    vsn = Keyword.fetch!(properties, :vsn)

    case Keyword.get(properties, :included_applications, []) do
      [] -> {app, vsn, mode}
      included_apps -> {app, vsn, mode, included_apps}
    end
  end

  defp post_stdlib_applies(instructions, release) do
    {pre, [stdlib | post]} =
      Enum.split_while(
        instructions,
        &(not match?({:apply, {:application, :start_boot, [:stdlib, _]}}, &1))
      )

    pre ++ [stdlib] ++ config_provider_apply(release) ++ post
  end

  defp config_provider_apply(%{config_providers: []}),
    do: []

  defp config_provider_apply(_),
    do: [{:apply, {Config.Provider, :boot, []}}]

  defp prepend_paths_to_script(instructions, []), do: instructions

  defp prepend_paths_to_script(instructions, prepend_paths) do
    prepend_paths = Enum.map(prepend_paths, &String.to_charlist/1)

    Enum.map(instructions, fn
      {:path, paths} ->
        if Enum.any?(paths, &List.starts_with?(&1, ~c"$RELEASE_LIB")) do
          {:path, prepend_paths ++ paths}
        else
          {:path, paths}
        end

      other ->
        other
    end)
  end

  defp consultable(term) do
    IO.chardata_to_string(:io_lib.format("%% coding: utf-8~n~tp.~n", [term]))
  end

  @doc """
  Finds a template path for the release.
  """
  @spec rel_templates_path(t, Path.t()) :: binary
  def rel_templates_path(release, path) do
    Path.join(release.options[:rel_templates_path] || "rel", path)
  end

  @doc """
  Copies ERTS if the release is configured to do so.

  Returns `true` if the release was copied, `false` otherwise.
  """
  @spec copy_erts(t) :: boolean()
  def copy_erts(%{erts_source: nil}) do
    false
  end

  def copy_erts(release) do
    destination = Path.join(release.path, "erts-#{release.erts_version}/bin")
    File.mkdir_p!(destination)

    release.erts_source
    |> Path.join("bin")
    |> File.cp_r!(destination, on_conflict: fn _, _ -> false end)

    _ = File.rm(Path.join(destination, "erl"))
    _ = File.rm(Path.join(destination, "erl.ini"))

    destination
    |> Path.join("erl")
    |> File.write!(~S"""
    #!/bin/sh
    SELF=$(readlink "$0" || true)
    if [ -z "$SELF" ]; then SELF="$0"; fi
    BINDIR="$(cd "$(dirname "$SELF")" && pwd -P)"
    ROOTDIR="${ERL_ROOTDIR:-"$(dirname "$(dirname "$BINDIR")")"}"
    EMU=beam
    PROGNAME=$(echo "$0" | sed 's/.*\///')
    export EMU
    export ROOTDIR
    export BINDIR
    export PROGNAME
    exec "$BINDIR/erlexec" ${1+"$@"}
    """)

    File.chmod!(Path.join(destination, "erl"), 0o755)
    true
  end

  @doc """
  Copies the given application specification into the release.

  It assumes the application exists in the release.
  """
  @spec copy_app(t, application) :: boolean()
  def copy_app(release, app) do
    properties = Map.fetch!(release.applications, app)
    vsn = Keyword.fetch!(properties, :vsn)

    source_app = Keyword.fetch!(properties, :path)
    target_app = Path.join([release.path, "lib", "#{app}-#{vsn}"])

    if is_nil(release.erts_source) and Keyword.fetch!(properties, :otp_app?) do
      false
    else
      File.rm_rf!(target_app)
      File.mkdir_p!(target_app)

      copy_ebin(release, Path.join(source_app, "ebin"), Path.join(target_app, "ebin"))

      for dir <- @copy_app_dirs do
        source_dir = Path.join(source_app, dir)
        target_dir = Path.join(target_app, dir)
        File.exists?(source_dir) && File.cp_r!(source_dir, target_dir, dereference_symlinks: true)
      end

      true
    end
  end

  @doc """
  Copies the ebin directory at `source` to `target`
  respecting release options such a `:strip_beams`.
  """
  @spec copy_ebin(t, Path.t(), Path.t()) :: boolean()
  def copy_ebin(release, source, target) do
    with {:ok, [_ | _] = files} <- File.ls(source) do
      File.mkdir_p!(target)

      strip_options =
        release.options
        |> Keyword.get(:strip_beams, true)
        |> parse_strip_beams_options()

      for file <- files do
        source_file = Path.join(source, file)
        target_file = Path.join(target, file)

        case Path.extname(file) do
          ".beam" ->
            process_beam_file(source_file, target_file, strip_options)

          ".app" ->
            process_app_file(source_file, target_file)

          _ ->
            # Use File.cp!/3 to preserve file mode for any executables stored
            # in the ebin directory.
            File.cp!(source_file, target_file)
        end
      end

      true
    else
      _ -> false
    end
  end

  defp process_beam_file(source_file, target_file, strip_options) do
    with true <- is_list(strip_options),
         {:ok, binary} <- strip_beam(File.read!(source_file), strip_options) do
      File.write!(target_file, binary)
    else
      _ -> File.cp!(source_file, target_file)
    end
  end

  defp process_app_file(source_file, target_file) do
    with {:ok, [{:application, app, info}]} <- :file.consult(source_file) do
      File.write!(target_file, :io_lib.format("~tp.~n", [{:application, app, info}]))
    else
      _ -> File.cp!(source_file, target_file)
    end
  end

  @doc """
  Strips a beam file for a release.

  This keeps only significant chunks necessary for the VM operation,
  discarding documentation, debug info, compile information and others.

  The exact chunks that are kept are not documented and may change in
  future versions.

  ## Options

    * `:keep` - a list of additional chunk names (as strings) to keep in the
      stripped BEAM file beyond those required by Erlang/Elixir

    * `:compress` - when `true`, the resulting BEAM file will be compressed
      using gzip. Defaults to `false`

  ## Examples

      # Strip with default options
      Mix.Release.strip_beam(beam_binary)

      # Keep additional chunks and compress
      Mix.Release.strip_beam(beam_binary, keep: ["Docs", "ChunkName"], compress: true)

  """
  @spec strip_beam(binary(), strip_beam_opts()) :: {:ok, binary()} | {:error, :beam_lib, term()}
  def strip_beam(binary, options \\ []) when is_list(options) do
    chunks_to_keep = options[:keep] |> List.wrap() |> Enum.map(&String.to_charlist/1)
    all_chunks = Enum.uniq(@additional_chunks ++ :beam_lib.significant_chunks() ++ chunks_to_keep)
    compress? = Keyword.get(options, :compress, false)

    case :beam_lib.chunks(binary, all_chunks, [:allow_missing_chunks]) do
      {:ok, {_, chunks}} ->
        chunks = for {name, chunk} <- chunks, is_binary(chunk), do: {name, chunk}
        {:ok, binary} = :beam_lib.build_module(chunks)

        if compress? do
          {:ok, :zlib.gzip(binary)}
        else
          {:ok, binary}
        end

      {:error, _, _} = error ->
        error
    end
  end

  defp parse_strip_beams_options(options) do
    case options do
      options when is_list(options) -> options
      true -> []
      false -> nil
    end
  end
end
