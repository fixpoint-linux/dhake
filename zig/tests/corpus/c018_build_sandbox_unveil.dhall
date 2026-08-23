let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, unveil = [ "rwc:./sandbox_ext" ] }
   , targets =
     [ { mapKey = "allow", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "echo a > sandbox_ext/a.txt" > ] } }
     , { mapKey = "deny", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "touch /dhake-landlock-other-$$" > ] } }
     ], default = "allow" }
