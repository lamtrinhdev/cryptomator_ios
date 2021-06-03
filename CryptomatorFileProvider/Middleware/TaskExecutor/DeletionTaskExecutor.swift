//
//  DeletionTaskExecutor.swift
//  CryptomatorFileProvider
//
//  Created by Philipp Schmid on 18.05.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import CryptomatorCloudAccessCore
import Foundation
import Promises
class DeletionTaskExecutor: WorkflowMiddleware {
	private var next: AnyWorkflowMiddleware<Void>?
	private let provider: CloudProvider
	private let metadataManager: MetadataManager

	init(provider: CloudProvider, metadataManager: MetadataManager) {
		self.provider = provider
		self.metadataManager = metadataManager
	}

	func execute(task: CloudTask) -> Promise<Void> {
		let itemMetadata = task.itemMetadata
		return deleteItemInCloud(itemMetadata).then {
			try self.metadataManager.removeItemMetadata(with: itemMetadata.id!)
		}
	}

	private func deleteItemInCloud(_ itemMetadata: ItemMetadata) -> Promise<Void> {
		switch itemMetadata.type {
		case .file:
			return provider.deleteFile(at: itemMetadata.cloudPath)
		case .folder:
			return provider.deleteFolder(at: itemMetadata.cloudPath)
		default:
			return Promise(FileProviderDecoratorError.unsupportedItemType)
		}
	}

	func setNext(_ next: AnyWorkflowMiddleware<Void>) {
		self.next = next
	}

	func getNext() throws -> AnyWorkflowMiddleware<Void> {
		guard let nextMiddleware = next else {
			throw WorkflowMiddlewareError.missingMiddleware
		}
		return nextMiddleware
	}
}
