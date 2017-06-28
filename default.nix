{ mkDerivation, async, base, contravariant, pipes, stdenv, stm
, void
}:
mkDerivation {
  pname = "pipes-concurrency";
  version = "2.0.7";
  src = ./.;
  libraryHaskellDepends = [ base contravariant pipes stm void ];
  testHaskellDepends = [ async base pipes stm ];
  description = "Concurrency for the pipes ecosystem";
  license = stdenv.lib.licenses.bsd3;
}
