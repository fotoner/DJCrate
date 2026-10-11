import DJCApplication

extension ReflectionPrompter {
    /// 유스케이스의 확인 포트(`UserConfirmation`)로: 물을지는 유스케이스가 정하고 이 창이 답한다
    var confirmation: UserConfirmation {
        UserConfirmation(confirm: { show($0) }, choose: { choose($0) })
    }
}
