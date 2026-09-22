let
  unique =
    values:
    builtins.foldl' (
      result: value: if builtins.elem value result then result else result ++ [ value ]
    ) [ ] values;
  allUnique = values: builtins.length values == builtins.length (unique values);
  validPort = port: builtins.isInt port && port >= 1 && port <= 65535;
in
{
  inherit allUnique unique;

  normalizeMac =
    builtins.replaceStrings
      [
        "A"
        "B"
        "C"
        "D"
        "E"
        "F"
      ]
      [
        "a"
        "b"
        "c"
        "d"
        "e"
        "f"
      ];

  validMacAddress =
    address:
    builtins.isString address && builtins.match "([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}" address != null;

  validPortList = ports: builtins.isList ports && builtins.all validPort ports && allUnique ports;
}
