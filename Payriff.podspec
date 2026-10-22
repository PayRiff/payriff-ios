Pod::Spec.new do |s|
  s.name              = 'Payriff'
  s.version           = '1.0.0'
  s.summary           = "Accept card payments with Payriff in a native iOS payment screen."
  s.description       = <<-DESC
    The Payriff iOS SDK pays an order your server created with a ready-made payment screen
    (PayriffPaymentView, PayriffPaymentScreen) or its building blocks, the native card form
    (PayriffCardForm, PayriffCardFormView). The card is encrypted on the device and sent with
    your publishable key and the order's client secret; 3-D Secure runs in a native sheet, and
    the SDK polls the order status and returns a typed PayriffResult. SwiftUI and UIKit are
    supported.
  DESC

  s.homepage          = 'https://payriff.com'
  s.documentation_url = 'https://docs.payriff.com'
  s.license           = { :type => 'Payriff SDK License', :file => 'LICENSE' }
  s.author            = 'Payriff'
  s.source            = { :git => 'https://github.com/PayRiff/payriff-ios.git', :tag => s.version.to_s }

  s.ios.deployment_target = '16.0'
  s.swift_version         = '6.0'

  s.source_files     = 'Sources/Payriff/**/*.swift'
  s.resource_bundles = {
    'Payriff_Privacy' => ['Sources/Payriff/Resources/PrivacyInfo.xcprivacy'],
    # The images of PayriffPaymentView (badges, logo) in 1x, 2x and 3x; the lock is drawn in code.
    'Payriff_PaymentView' => ['Sources/Payriff/Resources/PaymentView/*.png'],
  }
  s.frameworks       = 'Foundation', 'UIKit', 'WebKit', 'SwiftUI', 'CryptoKit', 'Security'
end
