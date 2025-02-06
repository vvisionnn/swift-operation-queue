import ConcurrencyExtras
import Foundation
import OrderedCollections

extension OrderedDictionary {
	func exists(_ key: Key) -> Bool {
		self[key] != nil
	}

	func notExists(_ key: Key) -> Bool {
		!exists(key)
	}
}
