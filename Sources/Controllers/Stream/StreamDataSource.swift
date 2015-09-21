//
//  StreamDataSource.swift
//  Ello
//
//  Created by Sean Dougherty on 11/22/14.
//  Copyright (c) 2014 Ello. All rights reserved.
//

import UIKit
import WebKit

public class StreamDataSource: NSObject, UICollectionViewDataSource {

    public typealias StreamContentReady = (indexPaths:[NSIndexPath]) -> Void
    public typealias StreamFilter = (StreamCellItem -> Bool)?

    public var streamKind:StreamKind
    public var currentUser: User?

    // these are the items assigned from the parent controller
    public var streamCellItems:[StreamCellItem] = []

    // these are either the same as streamCellItems (no filter) or if a filter
    // is applied this stores the filtered items
    public private(set) var visibleCellItems:[StreamCellItem] = []

    // if a filter is added or removed, we update the items
    public var streamFilter: StreamFilter {
        didSet { updateFilteredItems() }
    }

    // if a filter is added or removed, we update the items
    public var streamCollapsedFilter: StreamFilter {
        didSet { updateFilteredItems() }
    }

    public let textSizeCalculator: StreamTextCellSizeCalculator
    public let notificationSizeCalculator: StreamNotificationCellSizeCalculator
    public let profileHeaderSizeCalculator: ProfileHeaderCellSizeCalculator
    public let imageSizeCalculator: StreamImageCellSizeCalculator

    weak public var postbarDelegate: PostbarDelegate?
    weak public var createPostDelegate: CreatePostDelegate?
    weak public var notificationDelegate: NotificationDelegate?
    weak public var webLinkDelegate: WebLinkDelegate?
    weak public var imageDelegate: StreamImageCellDelegate?
    weak public var userDelegate: UserDelegate?
    weak public var relationshipDelegate: RelationshipDelegate?
    weak public var simpleStreamDelegate: SimpleStreamDelegate?
    weak public var inviteDelegate: InviteDelegate?
    public let inviteCache = InviteCache()

    public init(
        streamKind:StreamKind,
        textSizeCalculator: StreamTextCellSizeCalculator,
        notificationSizeCalculator: StreamNotificationCellSizeCalculator,
        profileHeaderSizeCalculator: ProfileHeaderCellSizeCalculator,
        imageSizeCalculator: StreamImageCellSizeCalculator)
    {
        self.streamKind = streamKind
        self.textSizeCalculator = textSizeCalculator
        self.notificationSizeCalculator = notificationSizeCalculator
        self.profileHeaderSizeCalculator = profileHeaderSizeCalculator
        self.imageSizeCalculator = imageSizeCalculator
        super.init()
    }

    // MARK: - Public

    public func removeAllCellItems() {
        streamCellItems = []
        updateFilteredItems()
    }

    public func indexPathForItem(item: StreamCellItem) -> NSIndexPath? {
        if let index = self.visibleCellItems.indexOf(item) {
            return NSIndexPath(forItem: index, inSection: 0)
        }
        return nil
    }

    public func userForIndexPath(indexPath: NSIndexPath) -> User? {
        let item = visibleStreamCellItem(at: indexPath)

        if let authorable = item?.jsonable as? Authorable {
            return authorable.author
        }
        return item?.jsonable as? User
    }

    public func postForIndexPath(indexPath: NSIndexPath) -> Post? {
        let item = visibleStreamCellItem(at: indexPath)

        if let notification = item?.jsonable as? Notification {
            if let comment = notification.activity.subject as? Comment {
                return comment.parentPost
            }
            return notification.activity.subject as? Post
        }
        return item?.jsonable as? Post
    }

    public func imageAssetForIndexPath(indexPath: NSIndexPath) -> Asset? {
        let item = visibleStreamCellItem(at: indexPath)
        let region = item?.type.data as? ImageRegion
        return region?.asset
    }

    public func commentForIndexPath(indexPath: NSIndexPath) -> Comment? {
        let item = visibleStreamCellItem(at: indexPath)
        return item?.jsonable as? Comment
    }

    public func visibleStreamCellItem(at indexPath: NSIndexPath) -> StreamCellItem? {
        if !isValidIndexPath(indexPath) { return nil }
        return visibleCellItems.safeValue(indexPath.item)
    }

    public func cellItemsForPost(post:Post) -> [StreamCellItem] {
        var tmp = [StreamCellItem]()
        temporarilyUnfilter {
            tmp = self.visibleCellItems.reduce([]) { arr, item in
                if let cellPost = item.jsonable as? Post where post.id == cellPost.id {
                    return arr + [item]
                }
                return arr
            }
        }
        return tmp
    }

    // this includes the `createComment` cell, `spacer` cell, and `seeMoreComments` cell since they contain a comment item
    public func commentIndexPathsForPost(post: Post) -> [NSIndexPath] {
        var indexPaths = [NSIndexPath]()
        for (index, value) in visibleCellItems.enumerate() {
            if let comment = value.jsonable as? Comment where comment.loadedFromPostId == post.id {
                indexPaths.append(NSIndexPath(forItem: index, inSection: 0))
            }
        }
        return indexPaths
    }

    public func footerIndexPathForPost(searchPost: Post) -> NSIndexPath? {
        for (index, value) in visibleCellItems.enumerate() {
            if value.type == .Footer,
               let post = value.jsonable as? Post {
                if searchPost.id == post.id {
                    return NSIndexPath(forItem: index, inSection: 0)
                }
            }
        }
        return nil
    }

    public func createCommentIndexPathForPost(post: Post) -> NSIndexPath? {
        let paths = commentIndexPathsForPost(post)
        if paths.count > 0 {
            let path = paths[0]
            if let createCommentItem = visibleStreamCellItem(at: path) {
                if createCommentItem.type == .CreateComment {
                    return path
                }
            }
        }
        return nil
    }

    public func removeCommentsForPost(post: Post) -> [NSIndexPath] {
        let indexPaths = self.commentIndexPathsForPost(post)
        temporarilyUnfilter() {
            // these paths might be different depending on the filter
            let unfilteredIndexPaths = self.commentIndexPathsForPost(post)
            var newItems = [StreamCellItem]()
            for (index, item) in self.streamCellItems.enumerate() {
                let skip = unfilteredIndexPaths.any { $0.item == index }
                if !skip {
                    newItems.append(item)
                }
            }
            self.streamCellItems = newItems
        }
        return indexPaths
    }

    public func removeItemAtIndexPath(indexPath: NSIndexPath) {
        if let itemToRemove = self.visibleCellItems.safeValue(indexPath.item) {
            temporarilyUnfilter() {
                if let index = self.streamCellItems.indexOf(itemToRemove) {
                    self.streamCellItems.removeAtIndex(index)
                }
            }
        }
    }

    public func updateHeightForIndexPath(indexPath: NSIndexPath, height: CGFloat) {
        if indexPath.item < visibleCellItems.count {
            visibleCellItems[indexPath.item].calculatedOneColumnCellHeight = height
            visibleCellItems[indexPath.item].calculatedMultiColumnCellHeight = height
        }
    }

    public func heightForIndexPath(indexPath:NSIndexPath, numberOfColumns:NSInteger) -> CGFloat {
        if !isValidIndexPath(indexPath) { return 0 }

        // alway try to return a calculated value before the default
        if numberOfColumns == 1 {
            return visibleCellItems[indexPath.item].calculatedOneColumnCellHeight ?? visibleCellItems[indexPath.item].type.oneColumnHeight ?? 0.0
        }
        else {
            return visibleCellItems[indexPath.item].calculatedMultiColumnCellHeight ?? visibleCellItems[indexPath.item].type.multiColumnHeight
        }
    }

    public func isFullWidthAtIndexPath(indexPath:NSIndexPath) -> Bool {
        if !isValidIndexPath(indexPath) { return true }
        return visibleCellItems[indexPath.item].type.isFullWidth
    }

    public func groupForIndexPath(indexPath:NSIndexPath) -> String {
        if !isValidIndexPath(indexPath) { return "0" }

        return (visibleCellItems[indexPath.item].jsonable as? Authorable)?.groupId ?? "0"
    }

    public func collectionView(collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return visibleCellItems.count ?? 0
    }

    public func collectionView(collectionView: UICollectionView, cellForItemAtIndexPath indexPath: NSIndexPath) -> UICollectionViewCell {
        if indexPath.item < visibleCellItems.count {
            let streamCellItem = visibleCellItems[indexPath.item]

            let cell = collectionView.dequeueReusableCellWithReuseIdentifier(streamCellItem.type.name, forIndexPath: indexPath)

            switch streamCellItem.type {
            case .Footer:
                (cell as! StreamFooterCell).delegate = postbarDelegate
            case .CreateComment:
                (cell as! StreamCreateCommentCell).delegate = postbarDelegate
            case .Header, .CommentHeader:
                (cell as! StreamHeaderCell).postbarDelegate = postbarDelegate
                (cell as! StreamHeaderCell).userDelegate = userDelegate
            case .Image:
                (cell as! StreamImageCell).streamImageCellDelegate = imageDelegate
            case .InviteFriends:
                (cell as! StreamInviteFriendsCell).inviteDelegate = inviteDelegate
                (cell as! StreamInviteFriendsCell).inviteCache = inviteCache
            case .Notification:
                (cell as! NotificationCell).webLinkDelegate = webLinkDelegate
                (cell as! NotificationCell).userDelegate = userDelegate
                (cell as! NotificationCell).delegate = notificationDelegate
            case .ProfileHeader:
                (cell as! ProfileHeaderCell).relationshipControl.relationshipDelegate = relationshipDelegate
                (cell as! ProfileHeaderCell).simpleStreamDelegate = simpleStreamDelegate
                (cell as! ProfileHeaderCell).webLinkDelegate = webLinkDelegate
            case .RepostHeader:
                (cell as! StreamRepostHeaderCell).userDelegate = userDelegate
            case .Text:
                (cell as! StreamTextCell).webLinkDelegate = webLinkDelegate
                (cell as! StreamTextCell).userDelegate = userDelegate
            case .UserAvatars:
                (cell as! UserAvatarsCell).simpleStreamDelegate = simpleStreamDelegate
                (cell as! UserAvatarsCell).userDelegate = userDelegate
            case .UserListItem:
                (cell as! UserListItemCell).relationshipControl.relationshipDelegate = relationshipDelegate
                (cell as! UserListItemCell).userDelegate = userDelegate
            default:
                break
            }

            streamCellItem.type.configure(
                cell: cell,
                streamCellItem: streamCellItem,
                streamKind: streamKind,
                indexPath: indexPath,
                currentUser: currentUser
            )

            return cell

        }
        return UICollectionViewCell()
    }

    public func modifyItems(jsonable: JSONAble, change: ContentChange, collectionView: UICollectionView) {
        // get items that match id and type -> [IndexPath]
        // based on change decide to update/remove those items
        switch change {
        case .Create:
            var indexPath: NSIndexPath?
            // if comment, add new comment cells
            if  let comment = jsonable as? Comment,
                let parentPost = comment.parentPost
            {
                let indexPaths = self.commentIndexPathsForPost(parentPost)
                if let first = indexPaths.first {
                    if self.visibleCellItems[first.item].type == .CreateComment {
                        indexPath = NSIndexPath(forItem: first.item + 1, inSection: first.section)
                    }
                }
            }

            // else if post, add new post cells
            else if let _ = jsonable as? Post {
                switch streamKind {
                case .Friend: indexPath = NSIndexPath(forItem: 0, inSection: 0)
                case .Profile: indexPath = NSIndexPath(forItem: 1, inSection: 0)
                case let .UserStream(userParam):
                    if currentUser?.id == userParam {
                        indexPath = NSIndexPath(forItem: 1, inSection: 0)
                    }
                default: break
                }
            }

            // else if love, add post to loves
            else if let _ = jsonable as? Love {
                switch streamKind {
                case let .SimpleStream(endpoint, _):
                    switch endpoint {
                    case .Loves: indexPath = NSIndexPath(forItem: 0, inSection: 0)
                    default: break
                    }
                default: break
                }
            }

            if let indexPath = indexPath {
                self.insertUnsizedCellItems(
                    StreamCellItemParser().parse([jsonable], streamKind: self.streamKind, currentUser: currentUser),
                    withWidth: UIWindow.windowWidth(),
                    startingIndexPath: indexPath)
                    { newIndexPaths in
                        collectionView.insertItemsAtIndexPaths(newIndexPaths)
                    }
            }

        case .Delete:
            collectionView.deleteItemsAtIndexPaths(removeItemsForJSONAble(jsonable, change: change))
        case .Replaced:
            let (oldIndexPaths, _) = elementsForJSONAble(jsonable, change: change)
            if let post = jsonable as? Post, firstIndexPath = oldIndexPaths.first {
                let firstIndexPath = oldIndexPaths.reduce(firstIndexPath) { (memo: NSIndexPath, path: NSIndexPath) in
                    if path.section == memo.section {
                        return path.item > memo.section ? memo : path
                    }
                    else {
                        return path.section > memo.section ? memo : path
                    }
                }
                let items = StreamCellItemParser().parse([post], streamKind: self.streamKind, currentUser: currentUser)
                insertUnsizedCellItems(items, withWidth: UIWindow.windowWidth(), startingIndexPath: firstIndexPath) { newIndexPaths in
                    for wrongIndexPath in Array(oldIndexPaths.reverse()) {
                        let indexPath = NSIndexPath(forItem: wrongIndexPath.item + newIndexPaths.count, inSection: wrongIndexPath.section)
                        self.removeItemAtIndexPath(indexPath)
                    }
                    collectionView.performBatchUpdates({
                        collectionView.insertItemsAtIndexPaths(newIndexPaths)
                        collectionView.deleteItemsAtIndexPaths(oldIndexPaths)
                    }, completion: nil)
                }
            }
            else if let comment = jsonable as? Comment, firstIndexPath = oldIndexPaths.first  {
                let firstIndexPath = oldIndexPaths.reduce(firstIndexPath) { (memo: NSIndexPath, path: NSIndexPath) in
                    if path.section == memo.section {
                        return path.item > memo.section ? memo : path
                    }
                    else {
                        return path.section > memo.section ? memo : path
                    }
                }
                let items = StreamCellItemParser().parse([comment], streamKind: self.streamKind, currentUser: currentUser)
                insertUnsizedCellItems(items, withWidth: UIWindow.windowWidth(), startingIndexPath: firstIndexPath) { newIndexPaths in
                    for wrongIndexPath in Array(oldIndexPaths.reverse()) {
                        let indexPath = NSIndexPath(forItem: wrongIndexPath.item + newIndexPaths.count, inSection: wrongIndexPath.section)
                        self.removeItemAtIndexPath(indexPath)
                    }
                    collectionView.performBatchUpdates({
                        collectionView.insertItemsAtIndexPaths(newIndexPaths)
                        collectionView.deleteItemsAtIndexPaths(oldIndexPaths)
                    }, completion: nil)
                }
            }
        case .Update:
            var shouldReload = true
            switch streamKind {
            case let .SimpleStream(endpoint, _):
                switch endpoint {
                case .Loves:
                    if let post = jsonable as? Post where !post.loved {
                        // the post was unloved
                        collectionView.deleteItemsAtIndexPaths(removeItemsForJSONAble(jsonable, change: .Delete))
                        shouldReload = false
                    }
                default: break
                }
            default: break
            }

            if shouldReload {
                let (indexPaths, items) = elementsForJSONAble(jsonable, change: change)
                for item in items {
                    item.jsonable = jsonable
                }
                collectionView.reloadItemsAtIndexPaths(indexPaths)
            }
        case .Loved:
            let (_, items) = elementsForJSONAble(jsonable, change: change)
            var indexPaths = [NSIndexPath]()
            for item in items {
                if let path = indexPathForItem(item)
                where item.type == .Footer {
                    indexPaths.append(path)
                }
                item.jsonable = jsonable
            }
            collectionView.reloadItemsAtIndexPaths(indexPaths)
        default: break
        }
    }

    public func modifyUserRelationshipItems(user: User, collectionView: UICollectionView) {
        switch user.relationshipPriority {
        case .Friend, .Noise, .Inactive:
            let changedItems = elementsForJSONAble(user, change: .Update)
            for item in changedItems.1 {
                if let oldUser = item.jsonable as? User {
                    // relationship changes
                    oldUser.relationshipPriority = user.relationshipPriority
                    oldUser.followersCount = user.followersCount
                    oldUser.followingCount = user.followingCount
                }
            }
            collectionView.reloadItemsAtIndexPaths(changedItems.0)
        case .Block, .Mute:
            modifyItems(user, change: .Delete, collectionView: collectionView)
        default: break
        }
        // TODO: figure out why the above doesn't update the counts.
        if user.id == currentUser?.id {
            modifyItems(user, change: .Update, collectionView: collectionView)
        }
    }

    public func modifyUserSettingsItems(user: User, collectionView: UICollectionView) {
        let changedItems = elementsForJSONAble(user, change: .Update)
        for item in changedItems.1 {
            if let _ = item.jsonable as? User {
                item.jsonable = user
            }
        }
        collectionView.reloadItemsAtIndexPaths(changedItems.0)
    }

    public func removeItemsForJSONAble(jsonable: JSONAble, change: ContentChange) -> [NSIndexPath] {
        let indexPaths = self.elementsForJSONAble(jsonable, change: change).0
        temporarilyUnfilter() {
            // these paths might be different depending on the filter
            let unfilteredIndexPaths = self.elementsForJSONAble(jsonable, change: change).0
            var newItems = [StreamCellItem]()
            for (index, item) in self.streamCellItems.enumerate() {
                let skip = unfilteredIndexPaths.any { $0.item == index }
                if !skip {
                    newItems.append(item)
                }
            }
            self.streamCellItems = newItems
        }
        return indexPaths
    }

    private func elementsForJSONAble(jsonable: JSONAble, change: ContentChange) -> ([NSIndexPath], [StreamCellItem]) {
        var indexPaths = [NSIndexPath]()
        var items = [StreamCellItem]()
        if let comment = jsonable as? Comment {
            for (index, item) in visibleCellItems.enumerate() {
                if let itemComment = item.jsonable as? Comment where comment.id == itemComment.id {
                    indexPaths.append(NSIndexPath(forItem: index, inSection: 0))
                    items.append(item)
                }
            }
        }
        else if let post = jsonable as? Post {
            for (index, item) in visibleCellItems.enumerate() {
                if let itemPost = item.jsonable as? Post where post.id == itemPost.id {
                    indexPaths.append(NSIndexPath(forItem: index, inSection: 0))
                    items.append(item)
                }
                else if change == .Delete || change == .Replaced {
                    if let itemComment = item.jsonable as? Comment where itemComment.loadedFromPostId == post.id || itemComment.postId == post.id {
                        indexPaths.append(NSIndexPath(forItem: index, inSection: 0))
                        items.append(item)
                    }
                }
            }
        }
        else if let user = jsonable as? User {
            for (index, item) in visibleCellItems.enumerate() {
                switch user.relationshipPriority {
                case .Block:
                    if let itemUser = item.jsonable as? User where user.id == itemUser.id {
                        indexPaths.append(NSIndexPath(forItem: index, inSection: 0))
                        items.append(item)
                    }
                    else if let itemComment = item.jsonable as? Comment {
                        if  user.id == itemComment.authorId ||
                            user.id == itemComment.parentPost?.authorId
                        {
                            indexPaths.append(NSIndexPath(forItem: index, inSection: 0))
                            items.append(item)
                        }
                    }
                    else if let itemPost = item.jsonable as? Post where user.id == itemPost.authorId {
                        indexPaths.append(NSIndexPath(forItem: index, inSection: 0))
                        items.append(item)
                    }
                case .Mute:
                    if streamKind.name == StreamKind.Notifications(category: nil).name {
                        if let itemNotification = item.jsonable as? Notification where user.id == itemNotification.author?.id {
                            indexPaths.append(NSIndexPath(forItem: index, inSection: 0))
                            items.append(item)
                        }
                    }
                default:
                    if let itemUser = item.jsonable as? User where user.id == itemUser.id {
                        indexPaths.append(NSIndexPath(forItem: index, inSection: 0))
                        items.append(item)
                    }
                }
            }
        }
        return (indexPaths, items)
    }

    // MARK: Adding items
    public func appendStreamCellItems(items: [StreamCellItem]) {
        self.streamCellItems += items
        self.updateFilteredItems()
    }

    public func appendUnsizedCellItems(cellItems: [StreamCellItem], withWidth: CGFloat, completion: StreamContentReady) {
        let startingIndexPath = NSIndexPath(forItem: self.streamCellItems.count, inSection: 0)
        insertUnsizedCellItems(cellItems, withWidth: withWidth, startingIndexPath: startingIndexPath, completion: completion)
    }

    public func insertStreamCellItems(cellItems: [StreamCellItem], startingIndexPath: NSIndexPath) -> [NSIndexPath] {
        // startingIndex represents the filtered index,
        // arrayIndex is the streamCellItems index
        let startingIndex = startingIndexPath.item
        var arrayIndex = startingIndexPath.item

        if let item = self.visibleStreamCellItem(at: startingIndexPath) {
            if let foundIndex = self.streamCellItems.indexOf(item) {
                arrayIndex = foundIndex
            }
        }
        else if arrayIndex == visibleCellItems.count {
            arrayIndex = streamCellItems.count
        }

        var indexPaths:[NSIndexPath] = []

        for (index, cellItem) in cellItems.enumerate() {
            indexPaths.append(NSIndexPath(forItem: startingIndex + index, inSection: startingIndexPath.section))

            let atIndex = arrayIndex + index
            if atIndex <= streamCellItems.count {
                streamCellItems.insert(cellItem, atIndex: arrayIndex + index)
            }
            else {
                streamCellItems.append(cellItem)
            }
        }

        self.updateFilteredItems()
        return indexPaths
    }

    public func insertUnsizedCellItems(cellItems: [StreamCellItem], withWidth: CGFloat, startingIndexPath: NSIndexPath, completion: StreamContentReady) {
        self.calculateCellItems(cellItems, withWidth: withWidth) {
            let indexPaths = self.insertStreamCellItems(cellItems, startingIndexPath: startingIndexPath)
            completion(indexPaths: indexPaths)
        }
    }

    public func toggleCollapsedForIndexPath(indexPath: NSIndexPath) {
        if let post = self.postForIndexPath(indexPath),
            let cellItem = self.visibleStreamCellItem(at: indexPath)
        {
            let newState: StreamCellState = cellItem.state == .Expanded ? .Collapsed : .Expanded
            let cellItems = self.cellItemsForPost(post)
            for item in cellItems {
                // don't toggle the footer's state, it is used by comment open/closed
                if item.type != .Footer {
                    item.state = newState
                }
            }
            self.updateFilteredItems()
        }
    }

    public func isValidIndexPath(indexPath: NSIndexPath) -> Bool {
        return indexPath.item >= 0 &&  indexPath.item < visibleCellItems.count && indexPath.section == 0
    }

    private func calculateCellItems(cellItems:[StreamCellItem], withWidth: CGFloat, completion: ElloEmptyCompletion) {
        let textCells = filterTextCells(cellItems)
        let imageCells = filterImageCells(cellItems)
        let notificationElements = cellItems.filter {
            return $0.type == StreamCellType.Notification
        }
        let profileHeaderItems = cellItems.filter {
            return $0.type == StreamCellType.ProfileHeader
        }
        let afterAll = after(4, block: completion)

        self.imageSizeCalculator.processCells(imageCells.normal, withWidth: withWidth) {
            self.imageSizeCalculator.processCells(imageCells.repost, withWidth: withWidth - 30.0, completion: afterAll)
        }
        // -30.0 acounts for the 15 on either side for constraints
        let textLeftRightConstraintWidth = (StreamTextCellPresenter.postMargin * 2)
        self.textSizeCalculator.processCells(textCells.normal, withWidth: withWidth - textLeftRightConstraintWidth) {
            // extra -30.0 acounts for the left indent on a repost with the black line
            self.textSizeCalculator.processCells(textCells.repost, withWidth: withWidth - (textLeftRightConstraintWidth * 2), completion: afterAll)
        }
        self.notificationSizeCalculator.processCells(notificationElements, withWidth: withWidth, completion: afterAll)
        self.profileHeaderSizeCalculator.processCells(profileHeaderItems, withWidth: withWidth, completion: afterAll)
    }

    private func filterTextCells(cellItems: [StreamCellItem]) -> (normal: [StreamCellItem], repost: [StreamCellItem]) {
        var cells = [StreamCellItem]()
        var repostCells = [StreamCellItem]()
        for item in cellItems {
            if let textRegion = item.type.data as? TextRegion {
                if textRegion.isRepost {
                    repostCells.append(item)
                }
                else {
                    cells.append(item)
                }
            }
        }
        return (cells, repostCells)
    }

    private func filterImageCells(cellItems: [StreamCellItem]) -> (normal: [StreamCellItem], repost: [StreamCellItem]) {
        var cells = [StreamCellItem]()
        var repostCells = [StreamCellItem]()
        for item in cellItems {
            if let imageRegion = item.type.data as? ImageRegion {
                if imageRegion.isRepost {
                    repostCells.append(item)
                }
                else {
                    cells.append(item)
                }
            }
            else if let embedRegion = item.type.data as? EmbedRegion {
                if embedRegion.isRepost {
                    repostCells.append(item)
                }
                else {
                    cells.append(item)
                }
            }
        }
        return (cells, repostCells)
    }

    private func temporarilyUnfilter(@noescape block: ElloEmptyCompletion) {
        let cachedStreamFilter = streamFilter
        let cachedStreamCollapsedFilter = streamCollapsedFilter
        self.streamFilter = nil
        self.streamCollapsedFilter = nil
        updateFilteredItems()

        block()

        self.streamFilter = cachedStreamFilter
        self.streamCollapsedFilter = cachedStreamCollapsedFilter
        updateFilteredItems()
    }

    private func updateFilteredItems() {
        self.visibleCellItems = self.streamCellItems

        if let streamFilter = streamFilter {
            self.visibleCellItems = self.visibleCellItems.filter { item in
                return item.alwaysShow() || streamFilter(item)
            }
        }

        if let streamCollapsedFilter = streamCollapsedFilter {
            self.visibleCellItems = self.visibleCellItems.filter { item in
                return item.alwaysShow() || streamCollapsedFilter(item)
            }
        }
    }
}


// MARK: For Testing
public extension StreamDataSource {
    public func testingElementsForJSONAble(jsonable: JSONAble, change: ContentChange) -> ([NSIndexPath], [StreamCellItem]) {
        return elementsForJSONAble(jsonable, change: change)
    }
}
