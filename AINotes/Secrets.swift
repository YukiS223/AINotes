//
//  Secrets.swift
//  AINotes
//
//  Created by 落 on 2026-05-15.
//
import Foundation

enum Secrets {
    static var anthropicAPIKey: String {
        guard
            let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let key = plist["ANTHROPIC_API_KEY"] as? String,
            !key.isEmpty
        else {
            fatalError("""
                Missing ANTHROPIC_API_KEY.
                Make sure Secrets.plist exists in the app target with key ANTHROPIC_API_KEY set to your sk-ant-... value.
                """)
        }
        return key
    }
}
