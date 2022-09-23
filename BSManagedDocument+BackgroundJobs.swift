import Foundation

extension BSManagedDocument {
    /**
     Creates a new, temporary background managed object context in the
     receiver's persistent container, and commands this context to
     "performAndWait" a given task specified by a closure
     */
    @objc
    func doInABackgroundContext (_ task: @escaping (_ context: NSManagedObjectContext?, _ error: Error?) -> Void) {
        let starksPersistentContainer = NSPersistentContainer(name: "for task: \(String.init(describing: task))",
                                                              managedObjectModel: self.managedObjectModel)
        if let storeUrl = Self.persistentStoreURL(forDocumentURL: self.fileURL) {
            let starksPersistentStoreDescription = NSPersistentStoreDescription(url: storeUrl)
            starksPersistentStoreDescription.type = NSSQLiteStoreType
            starksPersistentContainer.persistentStoreDescriptions = [starksPersistentStoreDescription]
            starksPersistentContainer.loadPersistentStores  { persistentStoreDescription, error in
                if (error == nil) {
                    let context = starksPersistentContainer.newBackgroundContext()
                    context.performAndWait {
                        task(context, nil)
                    }
                } else {
                  task(nil, error)
                }
            }
        }
    }
}
