let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text | Move : { from : Text, to : Text } | Symlink : { from : Text, to : Text } | Chmod : { path : Text, mode : Text } | Echo : Text | Env : { key : Text, value : Text } | Run : { argv : List Text } >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "a", mapValue = { deps = [], phony = True, recipe = [ < Touch = "a.stamp" > ] } }, { mapKey = "b", mapValue = { deps = [], phony = True, recipe = [ < Touch = "b.stamp" > ] } } ], default = "a" }
