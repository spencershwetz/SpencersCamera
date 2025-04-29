//
//  ContentView.swift
//  HorizontalWheelPicker
//
//  Created by Balaji Venkatesh on 15/03/24.
//

import SwiftUI

struct ContentView: View {
    @State private var config: WheelPicker.Config = .init(
        count: 30,
        steps: 10,
        spacing: 10,
        multiplier: 10
    )
    @State private var value: CGFloat = 10
    var body: some View {
        NavigationStack {
            VStack {
                HStack(alignment: .lastTextBaseline, spacing: 5, content: {
                    Text(verbatim: "\(value)")
                        .font(.largeTitle.bold())
                        .contentTransition(.numericText(value: value))
                        .animation(.snappy, value: value)
                    
                    Text("lbs")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .textScale(.secondary)
                        .foregroundStyle(.gray)
                })
                .padding(.vertical, 30)
                
                WheelPicker(config: config, value: $value)
                    .frame(height: 60)
                
                List {
                    Section("Count") {
                        Picker("", selection: $config.count) {
                            Text("10").tag(10)
                            Text("20").tag(20)
                            Text("30").tag(30)
                        }
                        .pickerStyle(.segmented)
                    }
                    
                    Section("Steps") {
                        Picker("", selection: $config.steps) {
                            Text("5").tag(5)
                            Text("10").tag(10)
                        }
                        .pickerStyle(.segmented)
                    }
                    
                    Section("Multiplier") {
                        Picker("", selection: $config.multiplier) {
                            Text("1").tag(1)
                            Text("10").tag(10)
                        }
                        .pickerStyle(.segmented)
                    }
                    
                    Section("Spacing") {
                        Slider(value: $config.spacing, in: 5...15)
                    }
                }
                .clipShape(.rect(cornerRadius: 15))
                .frame(height: 410)
                .padding(15)
                .padding(.top, 30)
            }
            .navigationTitle("Wheel Picker")
        }
    }
}

#Preview {
    ContentView()
}
