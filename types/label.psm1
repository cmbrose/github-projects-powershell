using module "./graphql-object-base.psm1"
using module "../common/client.psm1"

class Label: GraphQLObjectBase {
    [String]$Name

    [String]$Color

    # Constructor from value returned by $FetchSubQuery
    Label($queryResult) {
        $this.id = $queryResult.id
        $this.name = $queryResult.name
        $this.color = $queryResult.color
    }

    static [string]$FetchSubQuery = "
        id
        name
        color
    "
}
