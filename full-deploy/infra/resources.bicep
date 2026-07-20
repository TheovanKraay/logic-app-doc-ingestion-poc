@description('Primary location for all resources.')
param location string

@description('Environment name used to derive a unique resource token.')
param environmentName string

@description('Tags applied to all resources.')
param tags object = {}

@description('Location for the Azure OpenAI account (must have embedding model quota).')
param openAiLocation string = location

@description('Azure OpenAI embedding deployment name.')
param openAiEmbeddingDeployment string = 'text-embedding-3-small'

@description('Embedding model name.')
param openAiEmbeddingModel string = 'text-embedding-3-small'

@description('Embedding model version.')
param openAiEmbeddingModelVersion string = '1'

@description('TPM capacity (in thousands) for the embedding deployment.')
param openAiEmbeddingCapacity int = 120

@description('Deployment SKU for the embedding model (GlobalStandard usually has the most quota).')
param openAiEmbeddingSku string = 'GlobalStandard'

@description('Object (principal) ID of the user/service that uploads PDFs. If set, grants Storage Blob Data Contributor on the data account.')
param deployerPrincipalId string = ''

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

// Storage Blob Data Contributor for the human/service deploying the sample, so they
// can upload PDFs via the portal (shared key is disabled on the data account).
resource deployerBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  name: guid(dataStorage.id, deployerPrincipalId, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: dataStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: deployerPrincipalId
    principalType: 'User'
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
// Azure OpenAI (embeddings) and Document Intelligence (OCR). Key auth DISABLED;
// accessed via managed identity, matching the data-plane security model.
// ---------------------------------------------------------------------------
resource openAi 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: '${prefix}-aoai'
  location: openAiLocation
  tags: tags
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: '${prefix}-aoai'
    // The Azure OpenAI built-in Logic Apps connector supports only key-based or
    // AD-OAuth (app registration) auth - it has NO managed identity option - so key
    // auth must remain enabled here. Your data stores (Blob + Cosmos) stay key-free.
    disableLocalAuth: false
    publicNetworkAccess: 'Enabled'
  }
}

resource openAiEmbedding 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openAi
  name: openAiEmbeddingDeployment
  sku: { name: openAiEmbeddingSku, capacity: openAiEmbeddingCapacity }
  properties: {
    model: {
      format: 'OpenAI'
      name: openAiEmbeddingModel
      version: openAiEmbeddingModelVersion
    }
  }
}

resource docIntelligence 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: '${prefix}-docint'
  location: location
  tags: tags
  kind: 'FormRecognizer'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: '${prefix}-docint'
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

// Cognitive Services User for the Logic App's SYSTEM-assigned identity on the
// Document Intelligence account. The Document Intelligence connection uses
// "Logic Apps Managed Identity", which is the app's system-assigned identity.
resource docIntelSystemRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(docIntelligence.id, logicApp.id, 'a97b65f3-24c7-4388-baec-2e87135dc908')
  scope: docIntelligence
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a97b65f3-24c7-4388-baec-2e87135dc908')
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
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
    type: 'SystemAssigned, UserAssigned'
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
        { name: 'OPENAI_ENDPOINT', value: openAi.properties.endpoint }
        { name: 'OPENAI_EMBEDDING_DEPLOYMENT', value: openAiEmbeddingDeployment }
        { name: 'DOC_INTELLIGENCE_ENDPOINT', value: docIntelligence.properties.endpoint }
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
output openAiEndpoint string = openAi.properties.endpoint
output openAiEmbeddingDeployment string = openAiEmbeddingDeployment
output docIntelligenceEndpoint string = docIntelligence.properties.endpoint
