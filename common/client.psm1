class GraphQLClient {
    [string]$Token

    [string]$ApiUrl

    GraphQLClient(
        [string]$token
    ) {
        $this.token = $token
        $this.apiUrl = "https://api.github.com/graphql"
    }

    GraphQLClient(
        [string]$token,
        [string]$apiUrl
    ) {
        $this.token = $token
        $this.apiUrl = $apiUrl
    }

    [object]MakeRequest(
        [string]$query
    ) {
        return $this.MakeRequest($query, @{})
    }

    [object]MakeRequest(
        [string]$query, 
        [HashTable]$variables
    ) {
        $headers = @{
            "Authorization" = "Bearer $($this.token)";
            "GraphQL-Features" = "projects_next_graphql"; # Memex preview
            "Accept" = "application/vnd.github.bane-preview+json"; # Label preview
        }

        $body = @{
            query = $query;
            variables = $variables
        } | ConvertTo-Json -Depth 100

        $result = Invoke-WebRequest -Method POST -Uri $this.apiUrl -Headers $headers -Body $body -Verbose:$false
        | ForEach-Object { $_.Content } 
        | ConvertFrom-Json

        if ($result.errors) {
            throw $result.errors | ConvertTo-Json -Depth 100
        }

        return $result.data
    }
}

function New-GraphQLClient {
    param(
        [string]$token
    )

    if (-not $token) {
        throw "GitHub token not provided"
    }

    [GraphQLClient]::new($token)
}

function Invoke-GraphQLRequest {
    param(
        [string]$query,
        [string]$token,
        [HashTable]$variables = @{}
    )

    $client = New-GraphQLClient $token

    $client.MakeRequest($query, $variables)
}

Export-ModuleMember -Function "New-GraphQLClient"
Export-ModuleMember -Function "Invoke-GraphQLRequest"