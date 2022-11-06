import Foundation

extension BSManagedDocument {
    /**
     Creates a new, temporary background managed object context in the
     receiver's persistent container, and commands this context to
     "perform" a given task specified by a closure
     
     - important: If the context provided by this method might save changes,
     and if there is any possibility that other contexts, possibly in
     other processes, might make be making conflicting changes, in your `task`,
     be sure to set an appropriate merge policy on the provided `context`.
     The default NSMergePolicy.error is not appropriate in shipped code!
     
     - todo:  I'm really not sure if this func is a good practice.  Compared
     to just writing this code wherever it is needed, using this func may
     create "more heat than light".  Leaving it for now.
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
                    context.perform {
                        task(context, nil)
                    }
                } else {
                  task(nil, error)
                }
            }
        }
    }
}
