let
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/NixOs/nixpkgs/archive/09650059d7f5ae59a7f0fb2dd3bfc6d2042a74de.tar.gz";

    sha256 = "0f06zcc8mh934fya0hwzklmga238yxiyfp183y48vyzkdsg7xgn0";
  };

  overlay= pkgsNew: pkgsOld: {
    haskellPackages = pkgsOld.haskellPackages.override (old: {
      overrides =
        pkgsNew.lib.composeExtensions
          (old.overrides or (_: _: { }))
          (pkgsNew.haskell.lib.packageSourceOverrides {
            pipes-concurrency = ./.;
          });
    });
  };

  pkgs = import nixpkgs { config = { }; overlays = [ overlay ]; };

in
  { inherit (pkgs.haskellPackages) pipes-concurrency;

    shell = (pkgs.haskell.lib.doBenchmark pkgs.haskellPackages.pipes-concurrency).env;
  }
