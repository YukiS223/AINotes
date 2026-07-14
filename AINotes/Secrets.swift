//
//  Secrets.swift
//  AINotes
//
//  Created by 落 on 2026-05-15.
//
import Foundation

enum Secrets {
    static var geminiAPIKey: String {       // ← renamed from anthropicAPIKey
        guard
            let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let key = plist["geminiAPIKey"] as? String,
            !key.isEmpty
        else {
            fatalError("Missing geminiAPIKey in Secrets.plist")
        }
        return key
    }
}
