{
  root,
  super,
}:
/*
Use the Terra Blocktype for terraform configurations managed by terranix.

Important! You need to specify the state repo on the blocktype, e.g.:

[
  (terra "infra" "git@github.com:myorg/myrepo.git")
]

Available actions:
  - init
  - plan
  - apply
  - state
  - refresh
  - destroy
*/
let
  inherit (root) mkCommand;
  inherit (super) addSelectorFunctor postDiffToGitHubSnippet;
in
  name: repo: {
    inherit name;
    __functor = addSelectorFunctor;
    type = "terra";
    actions = {
      currentSystem,
      fragment,
      fragmentRelPath,
      target,
      inputs,
    }: let
      inherit (inputs) terranix;
      pkgs = inputs.nixpkgs.${currentSystem};

      git = {
        inherit repo;
        ref = "main";
        state = fragmentRelPath + "/state.json";
      };

      terraEval = import (terranix + /core/default.nix);
      terraformConfiguration = builtins.toFile "config.tf.json" (builtins.toJSON
        (terraEval {
          inherit pkgs; # only effectively required for `pkgs.lib`
          terranix_config = {
            _file = fragmentRelPath;
            imports = [target];
          };
          strip_nulls = true;
        })
        .config);

      setup = ''
        export TF_VAR_fragment=${pkgs.lib.strings.escapeShellArg fragment}
        export TF_VAR_fragmentRelPath=${fragmentRelPath}
        export TF_IN_AUTOMATION=1
        export TF_DATA_DIR="$PRJ_DATA_HOME/${fragmentRelPath}"
        export TF_PLUGIN_CACHE_DIR="$PRJ_CACHE_HOME/tf-plugin-cache"
        mkdir -p "$TF_DATA_DIR"
        mkdir -p "$TF_PLUGIN_CACHE_DIR"
        dir="$PRJ_ROOT/.tf/${fragmentRelPath}/.tf"
        mkdir -p "$dir"
        cat << MESSAGE > "$dir/readme.md"
        This is a tf staging area.
        It is motivated by the terraform CLI requiring to be executed in a staging area.
        MESSAGE

        if [[ -e "$dir/config.tf.json" ]]; then rm -f "$dir/config.tf.json"; fi
        jq '.' ${terraformConfiguration} > "$dir/config.tf.json"
      '';
      wrap = cmd: ''
        ${setup}

        # Run the command and capture output
        terraform-backend-git git \
           --dir "$dir" \
           --repository ${git.repo} \
           --ref ${git.ref} \
           --state ${git.state} \
           terraform ${cmd} "$@" \
           ${pkgs.lib.optionalString (cmd == "plan") ''
             -lock=false -no-color | tee "$PRJ_CACHE_HOME/tf.console.txt"
           ''}

        # Pass output to the snippet
        ${pkgs.lib.optionalString (cmd == "plan") ''
          output=$(cat "$PRJ_CACHE_HOME/tf.console.txt")
          summary_plan=$(tac "$PRJ_CACHE_HOME/tf.console.txt" | grep -m 1 -E '^(Error:|Plan:|Apply complete!|No changes.|Success)' | tac || echo "View output.")
          summary="<code>std ${fragmentRelPath}:${cmd}</code>: $summary_plan" 
          ${postDiffToGitHubSnippet "${fragmentRelPath}:${cmd}" "$output" "$summary"}
        ''}
      '';
      
    in [
      (mkCommand currentSystem "init" "tf init" [pkgs.jq pkgs.terraform pkgs.terraform-backend-git] (wrap "init") {})
      (mkCommand currentSystem "plan" "tf plan" [pkgs.jq pkgs.terraform pkgs.terraform-backend-git] (wrap "plan") {})
      (mkCommand currentSystem "apply" "tf apply" [pkgs.jq pkgs.terraform pkgs.terraform-backend-git] (wrap "apply") {})
      (mkCommand currentSystem "state" "tf state" [pkgs.jq pkgs.terraform pkgs.terraform-backend-git] (wrap "state") {})
      (mkCommand currentSystem "refresh" "tf refresh" [pkgs.jq pkgs.terraform pkgs.terraform-backend-git] (wrap "refresh") {})
      (mkCommand currentSystem "destroy" "tf destroy" [pkgs.jq pkgs.terraform pkgs.terraform-backend-git] (wrap "destroy") {})
      (mkCommand currentSystem "terraform" "pass any command to terraform" [pkgs.jq pkgs.terraform pkgs.terraform-backend-git] (wrap "") {})
    ];
  }
