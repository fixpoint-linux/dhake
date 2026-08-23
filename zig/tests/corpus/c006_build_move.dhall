let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text | Move : { from : Text, to : Text } | Symlink : { from : Text, to : Text } | Chmod : { path : Text, mode : Text } | Echo : Text | Env : { key : Text, value : Text } | Run : { argv : List Text } >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "move-target", mapValue = { deps = ["move_src.txt"], phony = False, recipe = [ < Move = { from = "move_src.txt", to = "move_dst.txt" } > ] } } ], default = "move-target" }
