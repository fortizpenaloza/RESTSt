Class {
	#name : #RESTfulAPIClient,
	#superclass : #Object,
	#instVars : [
		'httpClientProvider',
		'httpClientPoolByAuthority',
		'entityTagByLocationCache',
		'lastKnownRepresentationByLocation',
		'expiringCache'
	],
	#category : #'Superluminal-RESTfulAPI'
}

{ #category : #'instance creation' }
RESTfulAPIClient class >> buildingHttpClientWith: anHttpClientProvider [

	^self new initializeBuildingHttpClientWith: anHttpClientProvider
]

{ #category : #'instance creation' }
RESTfulAPIClient class >> default [

	^ self buildingHttpClientWith: [ ZnClient new ]
]

{ #category : #'private - caching' }
RESTfulAPIClient >> addSetIfNoneMatchHeaderTo: command configuredUsing: request ifCached: aLocation [

	self
		withCachedETagAt: aLocation
		do: [:entityTag | ^command + (request headers setIfNoneMatchTo: entityTag)].
	^command
]

{ #category : #'private - exception handling' }
RESTfulAPIClient >> clientErrorMessageFrom: response [

	response contentType
		ifNotNil: [ :contentType | 
			( contentType matches: ZnMimeType applicationJson )
				and: [ response contents
						ifNotNil: [ :contents | ( NeoJSONObject fromString: contents ) message ifNotNil: [ :message | ^ message ] ]
					]
			].

	^ 'Cannot complete the request'
]

{ #category : #'private - inkoving' }
RESTfulAPIClient >> clientPoolFor: aLocation [

	^ httpClientPoolByAuthority
		at: aLocation asUrl authorityWithPort
		ifAbsentPut: [ OPBasicPool new
				creator: httpClientProvider;
				destroyer: #close;
				passivator: #resetRequest;
				maxActiveObjects: 5;
				minIdleObjects: 1;
				yourself 
			]
]

{ #category : #invoking }
RESTfulAPIClient >> deleteAt: aLocation accepting: aMediaType withSuccessfulResponseDo: aBlock [

	^ self
		handleExceptionsDuring: [ 
			| httpRequest response |
			httpRequest := HttpRequest
				delete: aLocation
				configuredUsing: [ :request | 
					| command |
					command := request headers setAcceptTo: aMediaType.
					self
						withCachedETagAt: aLocation
						do: [ :entityTag | command := request headers setIfMatchTo: entityTag asString ].
					command
					].
			self
				withHttpClientFor: aLocation
				do: [ :httpClient | response := httpRequest applyOn: httpClient ].
			( response isSuccess or: [ response isNoContent ] )
				ifTrue: [ expiringCache clearResourceAt: aLocation.
					aBlock value: ( self tryToCacheContentsOf: response basedOn: aLocation )
					]
				ifFalse: [ self signalCannotCompleteDeleteErrorBasedOn: response code ]
			]
]

{ #category : #finalization }
RESTfulAPIClient >> finalize [

	httpClientPoolByAuthority
		valuesDo: [ :pool | 
			pool
				minIdleObjects: nil;
				clear
			].
	^ super finalize
]

{ #category : #invoking }
RESTfulAPIClient >> get: aLocation accepting: aMediaType withSuccessfulResponseDo: aBlock [

	^ self
		get: aLocation
		configuringRequestUsing: [ :request | request headers setAcceptTo: aMediaType ]
		withSuccessfulResponseDo: aBlock
]

{ #category : #'private - inkoving' }
RESTfulAPIClient >> get: aLocation configuringRequestUsing: aRequestBuildingBlock withSuccessfulResponseDo: aMonadicBlock [

	| key request |

	request := self requestToGet: aRequestBuildingBlock configuredUsing: aLocation.
	key := ExpiringCacheKeyBuilder keyFor: request at: aLocation.
	^ expiringCache
		withResourceAt: key
		obtainedUsing: [ self get: aLocation executing: request ]
		do: aMonadicBlock
]

{ #category : #'private - inkoving' }
RESTfulAPIClient >> get: aLocation executing: httpRequest [

	^ self
		handleExceptionsDuring: [ 
			| response contents |
			self
				withHttpClientFor: aLocation
				do: [ :httpClient | response := httpRequest applyOn: httpClient ].
			contents := response isNotModified
				ifTrue: [ self lastKnownRepresentationOf: aLocation ]
				ifFalse: [ response isSuccess
						ifTrue: [ self tryToCacheContentsOf: response basedOn: aLocation ]
						ifFalse: [ self raiseErrorBasedOn: response ]
					].
			ExpiringResource for: contents controlledBy: response
			]
]

{ #category : #invoking }
RESTfulAPIClient >> get: aLocation withSuccessfulResponseDo: aMonadicBlock [

	^ self get: aLocation configuringRequestUsing: [  ] withSuccessfulResponseDo: aMonadicBlock
]

{ #category : #'private - exception handling' }
RESTfulAPIClient >> handleExceptionsDuring: anInvokingBlock [

	^ [ anInvokingBlock
		on: NetworkError
		do:
			[ :signal | HTTPServerError signalInternalServerError: 'Cannot complete the request due to some network error' ]
	]
		on: AssertionFailed , InstanceCreationFailed , NeoJSONMappingNotFound , NeoJSONParseError
		do: [ :signal | HTTPClientError badRequest signal: signal messageText ]
]

{ #category : #initialization }
RESTfulAPIClient >> initializeBuildingHttpClientWith: anHttpClientProvider [

	httpClientProvider := anHttpClientProvider.
	httpClientPoolByAuthority := Dictionary new.
	entityTagByLocationCache := Dictionary new.
	lastKnownRepresentationByLocation := Dictionary new.
	expiringCache := ExpiringCache accordingTo: [ DateAndTime now ].
	self finalizationRegistry add: self
]

{ #category : #'private - caching' }
RESTfulAPIClient >> lastKnownRepresentationOf: aLocation [

	^lastKnownRepresentationByLocation at: (self normalize: aLocation)
]

{ #category : #'private - caching' }
RESTfulAPIClient >> normalize: aLocation [

	^aLocation asString
]

{ #category : #invoking }
RESTfulAPIClient >> patch: anEntity at: aLocation withSuccessfulResponseDo: aBlock [

	^ self
		handleExceptionsDuring: [ 
			| httpRequest response |
			httpRequest := HttpRequest
				patch: aLocation
				configuredUsing: [ :request | 
					| command |
					command := request body to: anEntity.
					self
						withCachedETagAt: aLocation
						do: [ :entityTag | command := command + ( request headers setIfMatchTo: entityTag asString ) ].
					command
					].
			self
				withHttpClientFor: aLocation
				do: [ :httpClient | response := httpRequest applyOn: httpClient ].
			response isSuccess
				ifTrue: [ expiringCache clearResourceAt: aLocation.
					aBlock value: ( self tryToCacheContentsOf: response basedOn: aLocation )
					]
				ifFalse: [ self signalCannotCompleteUpdateErrorBasedOn: response ]
			]
]

{ #category : #invoking }
RESTfulAPIClient >> post: anEntity at: aLocation withSuccessfulResponseDo: aBlock [

	^self handleExceptionsDuring: [| httpRequest response |
		httpRequest :=
			HttpRequest post: aLocation configuredUsing: [:request | request body to: anEntity].
		self
			withHttpClientFor: aLocation
			do: [:httpClient | response := httpRequest applyOn: httpClient].
		response isCreated
			ifTrue: [
				expiringCache clearResourceAt: aLocation.
				aBlock value: (self tryToCacheContentsOf: response basedOn: response location)]
			ifFalse: [
				(HTTPClientError code: response code) signal: (self clientErrorMessageFrom: response)]]
]

{ #category : #invoking }
RESTfulAPIClient >> put: anEntity at: aLocation [

	^ self
		handleExceptionsDuring: [ 
			| httpRequest response |
			httpRequest := HttpRequest
				put: aLocation
				configuredUsing: [ :request | request body to: anEntity ].
			self
				withHttpClientFor: aLocation
				do: [ :httpClient | response := httpRequest applyOn: httpClient ].
			response isNoContent
				ifTrue: [ expiringCache clearResourceAt: aLocation ]
				ifFalse: [ self signalCannotCompleteUpdateErrorBasedOn: response ]
			]
]

{ #category : #'private - inkoving' }
RESTfulAPIClient >> raiseErrorBasedOn: httpResponse [

	| message httpErrorClass |

	message := [ ( NeoJSONObject fromString: httpResponse contents ) at: #message ]
		on: Error
		do: [ :aSignal | aSignal return: 'Cannot complete the request' ].
	httpErrorClass := httpResponse code > 499
		ifTrue: [ HTTPServerError ]
		ifFalse: [ HTTPClientError ].
	( httpErrorClass code: httpResponse code ) signal: message
]

{ #category : #'private - inkoving' }
RESTfulAPIClient >> requestToGet: aRequestBuildingBlock configuredUsing: aLocation [

	^ HttpRequest
		get: aLocation
		configuredUsing: [ :request | 
			self
				addSetIfNoneMatchHeaderTo: aRequestBuildingBlock asHttpRequestCommand
				configuredUsing: request
				ifCached: aLocation
			]
]

{ #category : #'private - exception handling' }
RESTfulAPIClient >> signalCannotCompleteDeleteErrorBasedOn: response [

	^ ( HTTPClientError code: response code ) signal: 'Cannot complete delete'
]

{ #category : #'private - exception handling' }
RESTfulAPIClient >> signalCannotCompleteUpdateErrorBasedOn: response [

	^ ( HTTPClientError code: response code ) signal: 'Cannot complete update'
]

{ #category : #'private - caching' }
RESTfulAPIClient >> tryToCacheContentsOf: anHttpResponse basedOn: aLocation [

	| contents |

	contents := anHttpResponse contents.
	anHttpResponse
		withEntityTagDo: [:entityTag |
			entityTagByLocationCache at: (self normalize: aLocation) put: entityTag.
			lastKnownRepresentationByLocation at: (self normalize: aLocation) put: contents]
		ifAbsent: [
			entityTagByLocationCache removeKey: (self normalize: aLocation) ifAbsent: [].
			lastKnownRepresentationByLocation removeKey: (self normalize: aLocation) ifAbsent: []].
	^contents
]

{ #category : #'private - caching' }
RESTfulAPIClient >> withCachedETagAt: aLocation do: aBlock [

	^entityTagByLocationCache at: (self normalize: aLocation) ifPresent: aBlock
]

{ #category : #'private - inkoving' }
RESTfulAPIClient >> withHttpClientFor: aLocation do: aBlock [

	( self clientPoolFor: aLocation ) withPooled: aBlock
]