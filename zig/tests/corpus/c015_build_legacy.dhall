let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets =
     [ { mapKey = "mk", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Mkdir = "solo" > ] } }
     , { mapKey = "rmdir", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Rm = "legacy_dir" > ] } }
     ], default = "mk" }
