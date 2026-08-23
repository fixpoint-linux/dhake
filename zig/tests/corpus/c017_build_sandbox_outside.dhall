let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, unveil = [] : List Text }
   , targets = [ { mapKey = "bad", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "touch /dhake-landlock-outside-$$" > ] } } ], default = "bad" }
