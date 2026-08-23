let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text | Move : { from : Text, to : Text } | Symlink : { from : Text, to : Text } | Chmod : { path : Text, mode : Text } | Echo : Text | Env : { key : Text, value : Text } | Run : { argv : List Text } >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "symlink-target", mapValue = { deps = ["symlink_target.txt"], phony = False, recipe = [ < Symlink = { from = "symlink_target.txt", to = "symlink_link" } > ] } } ], default = "symlink-target" }
