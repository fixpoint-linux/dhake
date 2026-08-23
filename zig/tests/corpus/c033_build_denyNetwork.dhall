let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, denyNetwork = True, unveil = [] : List Text }
   , targets = [ { mapKey = "dn", mapValue = { deps = ["netprobe.c"], phony = False, recipe = [ < Shell = "cc -o netprobe netprobe.c && ./netprobe inet" > ] } } ], default = "dn" }
