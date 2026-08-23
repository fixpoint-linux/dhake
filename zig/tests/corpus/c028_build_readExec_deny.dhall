let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, readExec = True, unveil = [] : List Text }
   , targets = [ { mapKey = "deny-read", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "head -c1 /etc/passwd" > ] } } ], default = "deny-read" }
