@description('Primary location for all resources.')
param location string

@description('Environment name used to derive a unique resource token.')
param environmentName string

@description('Tags applied to all resources.')
param tags object = {}

@description('Azure OpenAI endpoint (bring your own).')
param openAiEndpoint string

@description('Azure OpenAI embedding deployment name.')
param openAiEmbeddingDeployment string

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var prefix = 'lai${resourceToken}'

// ---------------------------------------------------------------------------
// User-assigned managed identity (used for ALL data-plane access: blob + cosmos)
// ---------------------------------------------------------------------------
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-mi'
  location: location
  tags: tags
}

// ---------------------------------------------------------------------------
// DATA storage account: holds the source documents. Shared key DISABLED.
// Accessed only via managed identity (Storage Blob Data Reader).
// ---------------------------------------------------------------------------
resource dataStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: '${prefix}data'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource dataBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: dataStorage
  name: 'default'
}

resource dataContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: dataBlobService
  name: 'documents'
  properties: {
    publicAccess: 'None'
  }
}

// ---------------------------------------------------------------------------
// HOST storage account for the Logic App runtime (AzureWebJobsStorage + content
// share). Workflow Standard requires shared key for the Azure Files content
// share, so shared key is ENABLED here only. Holds NO customer documents.
// ---------------------------------------------------------------------------
resource hostStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: '${prefix}host'
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    allowSharedKeyAccess: true
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

// ---------------------------------------------------------------------------
// Cosmos DB for NoSQL with vector search. Local (key) auth DISABLED.
// Accessed via managed identity (Cosmos DB Built-in Data Contributor).
// ---------------------------------------------------------------------------
resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: '${prefix}-cosmos'
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    disableLocalAuth: true
    enableAutomaticFailover: false
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    locations: [
      { locationName: location, failoverPriority: 0, isZoneRedundant: false }
    ]
    capabilities: [
      { name: 'EnableNoSQLVectorSearch' }
    ]
  }
}

resource cosmosDb 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-11-15' = {
  parent: cosmos
  name: 'rag'
  properties: {
    resource: { id: 'rag' }
  }
}

resource cosmosContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = {
  parent: cosmosDb
  name: 'documents'
  properties: {
    resource: {
      id: 'documents'
      partitionKey: { paths: ['/id'], kind: 'Hash' }
      vectorEmbeddingPolicy: {
        vectorEmbeddings: [
          {
            path: '/embedding'
            dataType: 'float32'
            distanceFunction: 'cosine'
            dimensions: 1536
          }
        ]
      }
      indexingPolicy: {
        indexingMode: 'consistent'
        automatic: true
        includedPaths: [{ path: '/*' }]
        excludedPaths: [{ path: '/embedding/*' }]
        vectorIndexes: [{ path: '/embedding', type: 'diskANN' }]
      }
    }
  }
}

// Cosmos DB data-plane role assignment (built-in Data Contributor) for the identity
resource cosmosDataRole 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = {
  parent: cosmos
  name: guid(cosmos.id, uami.id, '00000000-0000-0000-0000-000000000002')
  properties: {
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    principalId: uami.properties.principalId
    scope: cosmos.id
  }
}

// Storage Blob Data Reader for the identity on the DATA account
resource blobDataReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dataStorage.id, uami.id, '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
  scope: dataStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Observability
// ---------------------------------------------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-law'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${prefix}-ai'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ---------------------------------------------------------------------------
// Logic App Standard (Workflow Standard plan)
// ---------------------------------------------------------------------------
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${prefix}-plan'
  location: location
  tags: tags
  sku: { name: 'WS1', tier: 'WorkflowStandard' }
  kind: 'elastic'
  properties: {
    targetWorkerCount: 1
    maximumElasticWorkerCount: 20
    elasticScaleEnabled: true
    zoneRedundant: false
  }
}

var hostStorageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${hostStorage.name};AccountKey=${hostStorage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

resource logicApp 'Microsoft.Web/sites@2023-12-01' = {
  name: '${prefix}-logic'
  location: location
  tags: union(tags, { 'azd-service-name': 'workflow' })
  kind: 'functionapp,workflowapp'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        { name: 'APP_KIND', value: 'workflowApp' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'dotnet' }
        { name: 'AzureWebJobsStorage', value: hostStorageConnectionString }
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', value: hostStorageConnectionString }
        { name: 'WEBSITE_CONTENTSHARE', value: '${prefix}-logic-content' }
        { name: 'AzureFunctionsJobHost__extensionBundle__id', value: 'Microsoft.Azure.Functions.ExtensionBundle.Workflows' }
        { name: 'AzureFunctionsJobHost__extensionBundle__version', value: '[1.*, 2.0.0)' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        // ---- Managed-identity data connections (consumed by connections.json) ----
        { name: 'AZURE_BLOB_STORAGE_ENDPOINT', value: dataStorage.properties.primaryEndpoints.blob }
        { name: 'WORKFLOWS_MANAGED_IDENTITY_CLIENTID', value: uami.properties.clientId }
        // ---- Workflow parameters ----
        { name: 'BLOB_CONTAINER_NAME', value: 'documents' }
        { name: 'COSMOS_ACCOUNT_NAME', value: cosmos.name }
        { name: 'COSMOS_DATABASE_NAME', value: 'rag' }
        { name: 'COSMOS_CONTAINER_NAME', value: 'documents' }
        { name: 'COSMOS_ENDPOINT', value: cosmos.properties.documentEndpoint }
        { name: 'CDB_VECTOR_PROPERTY', value: 'embedding' }
        { name: 'CDB_TEXT_PROPERTY', value: 'text' }
        { name: 'OPENAI_ENDPOINT', value: openAiEndpoint }
        { name: 'OPENAI_EMBEDDING_DEPLOYMENT', value: openAiEmbeddingDeployment }
        { name: 'WORKFLOWS_SUBSCRIPTION_ID', value: subscription().subscriptionId }
        { name: 'WORKFLOWS_RESOURCE_GROUP_NAME', value: resourceGroup().name }
        { name: 'WORKFLOWS_LOCATION_NAME', value: location }
      ]
    }
  }
}

output logicAppName string = logicApp.name
output dataStorageAccountName string = dataStorage.name
output dataContainerName string = 'documents'
output cosmosAccountName string = cosmos.name
output cosmosDatabaseName string = 'rag'
output cosmosContainerName string = 'documents'
output managedIdentityClientId string = uami.properties.clientId
output managedIdentityPrincipalId string = uami.properties.principalId
