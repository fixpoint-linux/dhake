let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, readExec = True, unveil = [] : List Text }
   , targets = [ { mapKey = "devnull", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "cat < /dev/null; test $? -eq 0" > ] } } ], default = "devnull" }
