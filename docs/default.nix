{
  runCommand,
  writeText,
  mdbook,
  optionsDoc,
}:
let
  repository = "https://github.com/ElXreno/nix-keenetic";

  book = writeText "book.toml" ''
    [book]
    title = "nix-keenetic"
    language = "en"
    src = "src"

    [output.html]
    git-repository-url = "${repository}"
    no-section-label = true
  '';

  summary = writeText "SUMMARY.md" ''
    # Summary

    [Introduction](introduction.md)
    [Options](options.md)
  '';
in
runCommand "nix-keenetic-docs" { nativeBuildInputs = [ mdbook ]; } ''
  mkdir -p book/src
  cp ${book} book/book.toml
  cp ${summary} book/src/SUMMARY.md
  sed -e 's|(LICENSE)|(${repository}/blob/main/LICENSE)|' ${../README.md} > book/src/introduction.md
  {
    echo "# Options"
    echo
    cat ${optionsDoc}
  } > book/src/options.md
  mdbook build book -d $out
''
