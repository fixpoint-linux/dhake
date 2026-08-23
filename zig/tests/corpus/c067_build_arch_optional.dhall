let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, arch : Optional Text }
in  { targets =
        [ { mapKey = "some-arm", mapValue = { deps = [] : List Text, phony = False, recipe = [ < Shell = "touch some_arm.out" > ], arch = Some "aarch64" } }
        , { mapKey = "none-any", mapValue = { deps = [] : List Text, phony = False, recipe = [ < Shell = "touch none_any.out" > ], arch = None Text } }
        ]
    , default = "none-any"
    }
