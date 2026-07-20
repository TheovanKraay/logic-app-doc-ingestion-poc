targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment used to generate a short unique hash for resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources.')
param location string

@description('Resource group to create.')
param resourceGroupName string = 'rg-${environmentName}'

@description('Azure OpenAI endpoint (e.g. https://my-aoai.openai.azure.com/). Bring your own.')
param openAiEndpoint string

@description('Azure OpenAI embedding deployment name (e.g. text-embedding-3-small).')
param openAiEmbeddingDeployment string = 'text-embedding-3-small'

var tags = {
  'azd-env-name': environmentName
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  // The skip tag below is only meaningful in subscriptions that enforce the
  // "disable local auth / no shared key" storage policy. The Logic App (Workflow
  // Standard) host storage account requires shared key for its Azure Files content
  // share. This tag scopes that allowance to THIS resource group only. It is a
  // harmless no-op in subscriptions without that policy.
  tags: union(tags, {
    'Az.Sec.DisableLocalAuth.Storage::Skip': 'true'
  })
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    location: location
    environmentName: environmentName
    tags: tags
    openAiEndpoint: openAiEndpoint
    openAiEmbeddingDeployment: openAiEmbeddingDeployment
  }
}

output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = rg.name
output LOGIC_APP_NAME string = resources.outputs.logicAppName
output DATA_STORAGE_ACCOUNT string = resources.outputs.dataStorageAccountName
output DATA_BLOB_CONTAINER string = resources.outputs.dataContainerName
output COSMOS_ACCOUNT_NAME string = resources.outputs.cosmosAccountName
output COSMOS_DATABASE_NAME string = resources.outputs.cosmosDatabaseName
output COSMOS_CONTAINER_NAME string = resources.outputs.cosmosContainerName
output MANAGED_IDENTITY_CLIENT_ID string = resources.outputs.managedIdentityClientId
