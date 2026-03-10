//
//  CustomAsyncPublisherTest.swift
//  CustomAsyncPublisher
//
//  Created by Saverio Negro on 3/10/26.
//

import SwiftUI

struct User: Identifiable, Codable {
    let id: Int
    let name: String
    let email: String
}

protocol NetworkingService<Data> {
    associatedtype Data: Codable
    func fetchData(from url: URL) async throws -> [Data]
}

protocol DataSource<Data>: Actor {
    associatedtype Data
    var data: [Data] { get set }
    var dataPublisher: Published<[Data]>.Publisher { get }
    func loadData() async -> Void
}

struct UserNetworkingService: NetworkingService {
    
    typealias Data = User
    
    func fetchData(from url: URL) async throws -> [Data] {
        
        let (usersData, _) = try await URLSession.shared.data(from: url)
        
        guard
            let decodedUsersData = try? JSONDecoder().decode([Data].self, from: usersData)
        else {
            throw URLError(.badServerResponse)
        }
        
        return decodedUsersData
    }
}

actor MockUserManager: DataSource {
    
    typealias Data = User
    
    @Published var data: [Data] = []
    var dataPublisher: Published<[Data]>.Publisher {
        return $data
    }
    
    let service: UserNetworkingService
    
    init(service: UserNetworkingService) {
        self.service = service
    }
    
    func loadData() async {
        
        let url = URL(string: "https://jsonplaceholder.typicode.com/users")!
        let users = try! await self.service.fetchData(from: url)
        
        // Fake user `data` being update over time
        for index in 0..<users.count {
           try? await Task.sleep(nanoseconds: UInt64(index * 500_000_000))
            
           self.data.append(users[index])
        }
    }
}

@Observable
class UsersViewModel<M: DataSource> {
    
    @MainActor private(set) var data: [M.Data] = []
    private let manager: M
    
    init(manager: M) {
        self.manager = manager
    }
    
    func loadData() async {
        // Concurrently load data from the manager and create an async stream that
        // awaits on emissions from the manager's published data's publisher.
        
        // Listen for emitted values from the publisher as the manager's user data
        // get updated — using an async sequence; namely, our `CustomAsyncPublisher`.
        Task {
            for await users in await self.manager.dataPublisher.customAsyncPublisher {
                
                if let lastUpdatedUser = users.last {
                    await MainActor.run {
                        self.data.append(lastUpdatedUser)
                    }
                }
            }
        }
        
        // Load user data from the manager over time
        Task {
            await self.manager.loadData()
        }
    }
}

struct UsersView: View {
    
    @State private var usersViewModel = UsersViewModel(
        manager: MockUserManager(service: UserNetworkingService())
    )
    
    var body: some View {
        ScrollView {
            VStack {
                ForEach(usersViewModel.data) { user in
                    VStack {
                        Text(user.name)
                            .font(.title)
                        Text(user.email)
                            .font(.headline)
                    }
                }
            }
        }
        .task {
            await usersViewModel.loadData()
        }
    }
}

#Preview {
    UsersView()
}

