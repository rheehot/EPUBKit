//
//  EPUB+PageCoordinator.swift
//  
//
//  Created by Jaehong Kang on 2020/01/16.
//

import Foundation
import Combine
import Shinjuku

#if canImport(CoreGraphics) && canImport(WebKit)
import CoreGraphics
import WebKit

extension CGSize: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(width)
        hasher.combine(height)
    }
}

extension EPUB {
    open class PageCoordinator: ObservableObject {
        private unowned var pageCoordinatorManager: PageCoordinatorManager

        private var spineItemHeightCalculateResultsByWidthSubscriber: AnyCancellable?
        private var epubStateSubscriber: AnyCancellable?

        lazy var offscreenPrerenderOperationQueue: OperationQueue = {
            let offscreenPrerenderOperationQueue = OperationQueue()

            offscreenPrerenderOperationQueue.underlyingQueue = DispatchQueue.main // Operation contains UIView which should be called on main thread even dealloc
            offscreenPrerenderOperationQueue.maxConcurrentOperationCount = 2

            return offscreenPrerenderOperationQueue
        }()

        open var epub: EPUB {
            return pageCoordinatorManager.epub
        }

        @Published open var pageSize: CGSize = .zero {
            didSet {
                if pageSize.width != oldValue.width {
                    calculateSpineItemHeights()
                }
            }
        }

        open var pagePositions: Result<[PagePosition], Swift.Error> {
            return pageCoordinatorManager.pagePositionsBySize[pageSize] ?? .success([])
        }

        open var pagePositionsPublisher: AnyPublisher<[PagePosition], Swift.Error> {
            return pageCoordinatorManager.$pagePositionsBySize
                .compactMap({ $0[self.pageSize] })
                .tryMap({ try $0.get() })
                .removeDuplicates()
                .eraseToAnyPublisher()
        }

        init(_ pageCoordinatorManager: PageCoordinatorManager) {
            self.pageCoordinatorManager = pageCoordinatorManager
            self.spineItemHeightCalculateResultsByWidthSubscriber = pageCoordinatorManager.$spineItemHeightCalculateResultsByWidth
                .compactMap({ [unowned self] in $0[self.pageSize.width] })
                .sink(receiveValue: { [unowned self](_) in
                    self.calculatePagePositions()
                })
            self.epubStateSubscriber = pageCoordinatorManager.epub.$state
                .sink(receiveValue: { [unowned self](state) in
                    switch state {
                    case .normal:
                        self.calculateSpineItemHeights()
                    default:
                        break
                    }
                })
        }

        deinit {
            offscreenPrerenderOperationQueue.cancelAllOperations()
        }

        open func spineItemHeightForRef(_ itemRef: Item.Ref) throws -> CGFloat? {
            try pageCoordinatorManager.spineItemHeightCalculateResultsByWidth[pageSize.width]?[itemRef]?.get()
        }

        open func spineItemHeightPublisherForRef(_ itemRef: Item.Ref) -> AnyPublisher<CGFloat, Swift.Error> {
            return pageCoordinatorManager.$spineItemHeightCalculateResultsByWidth
                .compactMap({ $0[self.pageSize.width] })
                .compactMap({ $0[itemRef] })
                .tryMap({ try $0.get() })
                .removeDuplicates()
                .eraseToAnyPublisher()
        }
    }
}

extension EPUB.PageCoordinator {
    func calculateSpineItemHeights() {
        let epub = self.epub

        guard
            let resourceURL = epub.resourceURL
        else {
            return
        }

        let pageSize = self.pageSize
        guard pageSize.width > 0 else {
            return
        }

        epub.mainQueue.async { [weak self, pageCoordinatorManager = self.pageCoordinatorManager] in
            epub.spine.itemRefs.forEach { (itemRef) in
                guard let item = epub.items[itemRef] else {
                    return
                }

                guard pageCoordinatorManager[pageWidth: pageSize.width][itemRef] == nil else {
                    return
                }

                let operation = OffscreenPrerenderOperation(
                    request: .fileURL(resourceURL.appendingPathComponent(item.relativePath), allowingReadAccessTo: resourceURL),
                    pageWidth: pageSize.width
                )
                operation.completionBlock = {
                    DispatchQueue.main.async { // For dealloc operation in Main Thread
                        guard case .finished(let result) = operation.state else {
                            return
                        }

                        pageCoordinatorManager[pageWidth: operation.pageWidth][itemRef] = result
                    }
                }

                self?.offscreenPrerenderOperationQueue.addOperation(operation)
            }
        }
    }

    func calculatePagePositions() {
        let epub = self.epub
        let pageSize = self.pageSize

        epub.mainQueue.async { [pageCoordinatorManager = self.pageCoordinatorManager] in
            let pagePositionsResult: Result<[EPUB.PagePosition], Swift.Error> = {
                do {
                    return .success(try epub.spine.itemRefs.flatMap { (itemRef) -> [EPUB.PagePosition] in
                        guard let spineItemHeightResult = pageCoordinatorManager.spineItemHeightCalculateResultsByWidth[pageSize.width]?[itemRef] else {
                            return []
                        }

                        let spineItemHeight = try spineItemHeightResult.get()

                        return (0..<Int(ceil(spineItemHeight / pageSize.height))).map {
                            return EPUB.PagePosition(
                                itemRef: itemRef,
                                contentYOffset: CGFloat($0) * pageSize.height,
                                contentSize: .init(width: pageSize.width, height: spineItemHeight),
                                pageSize: .init(width: pageSize.width, height: min(pageSize.height, spineItemHeight - (CGFloat($0) * pageSize.height)))
                            )
                        }

                    })
                } catch {
                    return .failure(error)
                }
            }()

            DispatchQueue.main.async {
                pageCoordinatorManager.pagePositionsBySize[pageSize] = pagePositionsResult
            }
        }
    }
}

extension EPUB.PageCoordinator: Identifiable { }

extension EPUB.PageCoordinator: Equatable {
    public static func == (lhs: EPUB.PageCoordinator, rhs: EPUB.PageCoordinator) -> Bool {
        lhs.id == rhs.id
    }
}

#endif
