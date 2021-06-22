//
//  FileProviderExtension.swift
//  FileProviderExtension
//
//  Created by Philipp Schmid on 17.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CocoaLumberjack
import CocoaLumberjackSwift
import CryptomatorCloudAccessCore
import CryptomatorCommonCore
import CryptomatorFileProvider
import FileProvider
import MSAL

class FileProviderExtension: NSFileProviderExtension, LocalURLProvider {
	var fileManager = FileManager()
	let fileCoordinator = NSFileCoordinator()
	var adapter: FileProviderAdapter?
	var observation: NSKeyValueObservation?
	var manager: NSFileProviderManager?
	var dbPath: URL?
	var notificator: FileProviderNotificator?
	static var databaseError: Error?
	static var sharedDatabaseInitialized = false
	override init() {
		super.init()
		LoggerSetup.oneTimeSetup()
		if !FileProviderExtension.sharedDatabaseInitialized {
			if let dbURL = CryptomatorDatabase.sharedDBURL {
				do {
					let dbPool = try CryptomatorDatabase.openSharedDatabase(at: dbURL)
					CryptomatorDatabase.shared = try CryptomatorDatabase(dbPool)
					FileProviderExtension.sharedDatabaseInitialized = true
					DropboxSetup.constants = DropboxSetup(appKey: CloudAccessSecrets.dropboxAppKey, sharedContainerIdentifier: CryptomatorConstants.appGroupName, keychainService: CryptomatorConstants.mainAppBundleId, forceForegroundSession: false)
					GoogleDriveSetup.constants = GoogleDriveSetup(clientId: CloudAccessSecrets.googleDriveClientId, redirectURL: CloudAccessSecrets.googleDriveRedirectURL!, sharedContainerIdentifier: CryptomatorConstants.appGroupName)
					OneDriveSetup.sharedContainerIdentifier = CryptomatorConstants.appGroupName
					let oneDriveConfiguration = MSALPublicClientApplicationConfig(clientId: CloudAccessSecrets.oneDriveClientId, redirectUri: CloudAccessSecrets.oneDriveRedirectURI, authority: nil)
					oneDriveConfiguration.cacheConfig.keychainSharingGroup = CryptomatorConstants.mainAppBundleId
					OneDriveSetup.clientApplication = try MSALPublicClientApplication(configuration: oneDriveConfiguration)
				} catch {
					// MARK: Handle error

					FileProviderExtension.databaseError = error
					DDLogError("Failed to initialize FPExt sharedDB: \(error)")
				}
			} else {
				// MARK: Handle error

				DDLogError("FPExt - dbURL is nil")
			}
		}

		self.observation = observe(
			\.domain,
			options: [.old, .new]
		) { _, change in
			DDLogInfo("domain changed from: \(change.oldValue) to: \(change.newValue)")
			do {
				try self.setUp()
			} catch {
				DDLogError("setUp decorator from kvo failed: \(error)")
			}
		}
	}

	deinit {
		observation?.invalidate()
		fileCoordinator.cancel()
	}

	/**
	 To support `NSExtensionFileProviderSupportsPickingFolders` it is necessary that we return an empty root item for additional identifiers. This includes the identifier "File Provider Storage", since this is the second to last folder in the URL that is responsible for opening this file provider domain.
	 In addition, for all files that are located directly in the local root folder of the file provider domain (e.g. the file provider database), we get the file provider domain as identifier.
	 Since we do not want to display these files externally, an empty RootItem is also returned for them.
	 */
	override func item(for identifier: NSFileProviderItemIdentifier) throws -> NSFileProviderItem {
		// resolve the given identifier to a record in the model
		if identifier == .rootContainer || identifier.rawValue == "File Provider Storage" || identifier.rawValue == domain?.identifier.rawValue {
			return RootFileProviderItem()
		}
		guard let adapter = self.adapter else {
			// no domain ==> no installed vault
			// TODO: Change error Code here
			throw NSFileProviderError(.notAuthenticated)
		}
		return try adapter.item(for: identifier)
	}

	override func urlForItem(withPersistentIdentifier identifier: NSFileProviderItemIdentifier) -> URL? {
		// resolve the given identifier to a file on disk
		if identifier == .rootContainer {
			return getBaseStorageDirectory()
		}
		guard let item = try? item(for: identifier) else {
			return nil
		}

		// in this implementation, all paths are structured as <base storage directory>/<item identifier>/<item file name>
		let baseStorageDirectoryURL = getBaseStorageDirectory()
		let perItemDirectory = baseStorageDirectoryURL?.appendingPathComponent(identifier.rawValue, isDirectory: true)
		return perItemDirectory?.appendingPathComponent(item.filename, isDirectory: false)
	}

	override func persistentIdentifierForItem(at url: URL) -> NSFileProviderItemIdentifier? {
		// resolve the given URL to a persistent identifier using a database
		let pathComponents = url.pathComponents

		// exploit the fact that the path structure has been defined as
		// <base storage directory>/<item identifier>/<item file name> above
		assert(pathComponents.count > 2)

		return NSFileProviderItemIdentifier(pathComponents[pathComponents.count - 2])
	}

	override func providePlaceholder(at url: URL, completionHandler: @escaping (Error?) -> Void) {
		guard let identifier = persistentIdentifierForItem(at: url) else {
			completionHandler(NSFileProviderError(.noSuchItem))
			return
		}
		do {
			let fileProviderItem = try item(for: identifier)
			let placeholderURL = NSFileProviderManager.placeholderURL(for: url)
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
			try NSFileProviderManager.writePlaceholder(at: placeholderURL, withMetadata: fileProviderItem)
			completionHandler(nil)
		} catch {
			completionHandler(error)
		}
	}

	override func startProvidingItem(at url: URL, completionHandler: @escaping ((_ error: Error?) -> Void)) {
		// Should ensure that the actual file is in the position returned by URLForItemWithIdentifier:, then call the completion handler

		/* TODO:
		 This is one of the main entry points of the file provider. We need to check whether the file already exists on disk,
		 whether we know of a more recent version of the file, and implement a policy for these cases. Pseudocode:

		 if !fileOnDisk {
		     downloadRemoteFile()
		     callCompletion(downloadErrorOrNil)
		 } else if fileIsCurrent {
		     callCompletion(nil)
		 } else {
		     if localFileHasChanges {
		         // in this case, a version of the file is on disk, but we know of a more recent version
		         // we need to implement a strategy to resolve this conflict
		         moveLocalFileAside()
		         scheduleUploadOfLocalFile()
		         downloadRemoteFile()
		         callCompletion(downloadErrorOrNil)
		     } else {
		         downloadRemoteFile()
		         callCompletion(downloadErrorOrNil)
		     }
		 }
		 */
		// TODO: Register DownloadTask
		guard let adapter = self.adapter else {
			// no domain ==> no installed vault
			// TODO: Change error Code here
			completionHandler(NSFileProviderError(.notAuthenticated))
			return
		}
		adapter.startProvidingItem(at: url, completionHandler: completionHandler)
	}

	override func itemChanged(at url: URL) {
		// Called at some point after the file has changed; the provider may then trigger an upload

		/* TODO:
		 - mark file at <url> as needing an update in the model
		 - if there are existing NSURLSessionTasks uploading this file, cancel them
		 - create a fresh background NSURLSessionTask and schedule it to upload the current modifications
		 - register the NSURLSessionTask with NSFileProviderManager to provide progress updates
		 */

		guard let adapter = self.adapter else {
			// no domain ==> no installed vault
			return
		}
		adapter.itemChanged(at: url)
	}

	override func stopProvidingItem(at url: URL) {
		// ### Apple template comments: ###
		// Called after the last claim to the file has been released. At this point, it is safe for the file provider to remove the content file.
		// Care should be taken that the corresponding placeholder file stays behind after the content file has been deleted.

		// TODO: look up whether the file has local changes
		//		let fileHasLocalChanges = false
		//
		//		if !fileHasLocalChanges {
		//			// remove the existing file to free up space
		//			do {
		//				_ = try FileManager.default.removeItem(at: url)
		//			} catch {
		//				// Handle error
		//			}
		//
		//			// write out a placeholder to facilitate future property lookups
		//			providePlaceholder(at: url, completionHandler: { _ in
		//				// TODO: handle any error, do any necessary cleanup
		//            })
		//		}

		// Not implemented in the moment.
		DDLogInfo("stopProvidingItem called for: \(url)")
	}

	// MARK: - Actions

	/* TODO: implement the actions for items here
	 each of the actions follows the same pattern:
	 - make a note of the change in the local model
	 - schedule a server request as a background task to inform the server of the change
	 - call the completion block with the modified item in its post-modification state
	 */

	// MARK: - Enumeration

	override func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier) throws -> NSFileProviderEnumerator {
		/* let maybeEnumerator: NSFileProviderEnumerator? = nil
		 if containerItemIdentifier == NSFileProviderItemIdentifier.rootContainer {
		 	// TODO: instantiate an enumerator for the container root
		 } else if containerItemIdentifier == NSFileProviderItemIdentifier.workingSet {
		 	// TODO: instantiate an enumerator for the working set
		 } else {
		 	// TODO: determine if the item is a directory or a file
		 	// - for a directory, instantiate an enumerator of its subitems
		 	// - for a file, instantiate an enumerator that observes changes to the file
		 }
		 guard let enumerator = maybeEnumerator else {
		 	throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:])
		 }
		 return enumerator
		 */
		// TODO: Change error handling here
		guard let manager = self.manager, let domain = self.domain, let dbPath = dbPath, let notificator = notificator else {
			// no domain ==> no installed vault
			DDLogError("FPExtension: not initialized")
			throw NSFileProviderError(.notAuthenticated)
		}
		return FileProviderEnumerator(enumeratedItemIdentifier: containerItemIdentifier, notificator: notificator, domain: domain, manager: manager, dbPath: dbPath, localURLProvider: self)
	}

	func setUp() throws {
		if let domain = self.domain {
			guard let manager = NSFileProviderManager(for: domain) else {
				throw FileProviderDecoratorSetupError.fileProviderManagerIsNil
			}
			self.manager = manager
			let dbPath = manager.documentStorageURL.appendingPathComponent(domain.pathRelativeToDocumentStorage, isDirectory: true).appendingPathComponent("db.sqlite")
			self.dbPath = dbPath
			let notificator = FileProviderNotificator(manager: manager)
			self.notificator = notificator
			FileProviderAdapterManager.getAdapter(for: domain, with: manager, dbPath: dbPath, delegate: self, notificator: notificator).then { adapter in
				self.adapter = adapter
			}
		} else {
			DDLogInfo("setUpDecorator called with nil domain")
			throw FileProviderDecoratorSetupError.domainIsNil
		}
	}

	private func getBaseStorageDirectory() -> URL? {
		guard let domain = domain else {
			DDLogError("getBaseStorageDirectory: domain is nil")
			return nil
		}
		let domainDocumentStorage = domain.pathRelativeToDocumentStorage
		let manager = NSFileProviderManager.default
		return manager.documentStorageURL.appendingPathComponent(domainDocumentStorage)
	}

	override func supportedServiceSources(for itemIdentifier: NSFileProviderItemIdentifier) throws -> [NSFileProviderServiceSource] {
		var serviceSources = [NSFileProviderServiceSource]()
		#if DEBUG
		serviceSources.append(FileProviderValidationServiceSource(fileProviderExtension: self, itemIdentifier: itemIdentifier))
		#endif
		return serviceSources
	}
}

enum FileProviderDecoratorSetupError: Error {
	case fileProviderManagerIsNil
	case domainIsNil
}

extension URL {
	func appendPathComponents(from other: URL, startIndex: Int = 1) -> URL {
		precondition(startIndex > 0)
		precondition(hasDirectoryPath)
		var result = self
		let components = other.pathComponents
		for i in startIndex ..< components.count {
			let isDirectory = (i < components.count - 1 || other.hasDirectoryPath)
			result.appendPathComponent(components[i], isDirectory: isDirectory)
		}
		return result
	}
}
